
AWS               = require 'aws-sdk'
cloudflare        = require 'cloudflare'
AWS_DEPLOY_KEY    = require("fs").readFileSync("#{__dirname}/../install/keys/aws/koding-prod-deployment.pem")
AWS.config.region = 'us-east-1'
cf                = cloudflare.createClient email: "devrim@kodingen.com", token: "2add2eaa830113aa9047ce0e90ea40bb95105"

AWS.config.update accessKeyId: 'AKIAI7RHT42HWAA652LA', secretAccessKey: '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'

argv              = require('minimist')(process.argv.slice(2))
eden              = require 'node-eden'
log               = console.log
timethat          = require 'timethat'
Connection        = require "ssh2"
fs                = require 'fs'
semver            = require 'semver'
{exec}            = require 'child_process'
request           = require 'request'
ec2               = new AWS.EC2()
elb               = new AWS.ELB()
cloudformation    = new AWS.CloudFormation()

runAfter     = (time,fn) -> setTimeout(fn,time)
runEvery     = (time,fn) ->
    a = setInterval(fn,time);
    return a;


class Release

    works = ->
        elb.deregisterInstancesFromLoadBalancer
            Instances                : [{ InstanceId: 'i-dd310cf7' }]
            LoadBalancerName : "koding-prod-deployment"
        ,(err,res) ->
            log err,res


        elb.registerInstancesWithLoadBalancer
            Instances                : [{ InstanceId: 'i-dd310cf7' }]
            LoadBalancerName : "koding-prod-deployment"
        ,(err,res) ->
            log err,res


        elb.describeInstanceHealth
            Instances                : [{ InstanceId: 'i-dd310cf7' }]
            LoadBalancerName : "koding-prod-deployment"
        ,(err,res)->
            log err,res

    domainCleanup : ->
        # keep it manual for now.
        cf.listDomainRecords "koding.io",(err,res)->
            for i in res
                unless i.name is "cammy.koding.io" or i.name is "koding.io"
                    log i.name, i.rec_id
                    cf.deleteDomainRecord "koding.io",i.rec_id,->


    @fetchLoadBalancerInstances = (LoadBalancerName,callback)->
        elb.describeLoadBalancers LoadBalancerNames : [LoadBalancerName],(err,res)->
            throw err if err
            instances = (x for x in res.LoadBalancerDescriptions[0].Instances)
            callback null,instances


    fetchInstancesWithPrefix = (prefix,callback)->

        pickValueOf= (key,array) -> return val.Value if val.Key is key for val in array
        instances = []
        ec2.describeInstances {},(err,res)->
            for r in res.Reservations
                instances = ( rr.InstanceId for rr in r.Instances when (pickValueOf "Name",rr.Tags).indexOf(prefix) > -1)
            callback null,instances

    @registerInstancesWithPrefix = (prefix, callback)->
        fetchInstancesWithPrefix prefix, (err,instances)->
            log "will register -->", instances
            Release.fetchLoadBalancerInstances "koding-prod-deployment",(err,instancesToDeregister)->

                # log "current items -->",res

                elb.registerInstancesWithLoadBalancer
                    Instances                : instances
                    LoadBalancerName : "koding-prod-deployment"
                ,(err,res)->
                    unless err
                        elb.deregisterInstancesFromLoadBalancer
                            Instances                : instancesToDeregister
                            LoadBalancerName : "koding-prod-deployment"
                            , callback
                    else
                        log "error registering instances to ELB, nothing changed. Check koding-prod-deployment ELB to make sure."
                        log err
                        callback err

    @deregisterInstancesWithPrefix = (prefix, callback)->
        fetchInstancesWithPrefix prefix, (err,instances)->
            log instances
            elb.deregisterInstancesFromLoadBalancer
                Instances                : instances
                LoadBalancerName : "koding-prod-deployment"
            ,callback



class Deploy

    @connect = (options,callback) ->
        {IP,username,password,retries,timeout} = options

        options.retry = yes unless options.retrying

        conn = new Connection()

        listen = (prefix, stream, callback)->
            _log = (data) -> log ("#{prefix} #{data}").replace("\n","") if data or data is not ""
            stream.on                    "data", _log
            stream.stderr.on     "data", _log
            stream.on "close", callback
            # stream.on "exit", (code, signal) -> log "[#{prefix}] did exit."

        sftpCopy = (options, callback)->
            copyCount = 1
            results = []
            options.conn.sftp (err, sftp) ->
                for file,nr in options.files
                    do (file)->
                        sftp.fastPut file.src,file.trg,(err,res)->
                            if err
                                log "couldn't copy:",file
                                throw err
                            log file.src+" is copied to "+file.trg
                            if copyCount is options.files.length then callback null,"done"
                            copyCount++

        conn.connect
            host                 : IP
            port                 : 22
            username         : username
            privateKey     : AWS_DEPLOY_KEY
            readyTimeout : timeout


        conn.on "ready", ->
            conn.listen     = listen
            conn.sftpCopy = sftpCopy
            callback null,conn

        conn.on "error", (err) -> retry()


        retry = ->
            if options.retries > 1
                options.retries = options.retries-1
                log "connecting to instance.. attempts left:#{options.retries}"
                setTimeout (-> Deploy.connect options, callback),timeout
            else
                log "not retrying anymore.", options.retries
                callback "error connecting."

    @remoteTail = (IP, username, path)->
        Deploy.connect
            username    : username
            IP                : IP
            retries     : 30
            timeout     : 5000
        , (err,conn)->
            conn.exec "tail -fq #{path}",(err,stream)->
                conn.listen "[tailing #{IP}]",stream,->
                    conn.end()


    @createLoadBalancer = (options,callback)->
        elb.createLoadBalancer
            LoadBalancerName : options.name
            Listeners : [
                InstancePort         : 80
                LoadBalancerPort : 80
                Protocol                 : "http"
                InstanceProtocol : "http"
            ]
            Subnets                : ["subnet-b47692ed"]
            SecurityGroups : ["sg-64126d01"]
        ,callback

    @tagInstances = (options,callback)->

        instanceIds = (instanceId for instance in options.Instances)

        ec2.createTags
            Resources : [instanceIds]
            Tags            : [{Key: "Name", Value: options.instanceName+"-#{key}"}]
        ,(err) ->
            log "Box tagged with #{instanceName}", (if err then "failure" else "success")
            if key is options.instances.length-1
                callback null

    @createInstances = (options={}, callback) ->
        params = options.params

        iamcalledonce = 0


        ec2.runInstances params, (err, data) ->
            iamcalledonce++
            if iamcalledonce > 1 then return log "i am called #{iamcalledonce} times"
            if err
                # log "\n\nCould not create instance ---->", err
                log """code:#{err.code},name:#{err.name},code:#{err.statusCode},#{err.retryable}
                 ---
                 [ERROR] #{err.message}
                \n\n
                """
                return
            else
                instanceIds = (instance.InstanceId for instance in data.Instances)
                log instanceIds
                ec2.createTags
                    Resources : instanceIds
                    Tags            : [{Key: "Name", Value: options.instanceName}]
                ,(err) ->
                    log "Boxes tagged with #{options.instanceName}", (if err then "failure" else "success")

                    callback null, data

    @addDomainRecord = (options,callback)->
        ttl = 120 or options.ttl
        {name, domain} = options
        fulldomain = "#{name}.#{domain}"

        cf.addDomainRecord options.domain,
            type : "A"
            name : options.name
            content : options.content
            service_mode : options.service_mode
        ,(err,res)->
            callback err if err
            # this additional step is required to enable cloudflare (https)
            cf.editDomainRecord options.domain,res.rec_id,
                type : options.type
                name : options.name
                content : options.content
                service_mode : options.service_mode
                ttl: ttl
            ,(err,data) ->

                #check if it already exists and delete all except the newly created above
                cf.listDomainRecords domain,(err,list)->
                    exists = false
                    for i,k in list
                        # log i.rec_id,i.name
                        unless i.rec_id is res.rec_id
                            log "deleting",i.name
                            exists = yes
                            cf.deleteDomainRecord domain, i.rec_id, ->

                callback null






    @deployTest = (options,callback)->

        i = 0
        result = []
        options.forEach (option) ->

            {target, url, expectString} = option
            __start = new Date()
            request url:url,timeout:5000,(err,res,body)->
                i++
                __end = timethat.calc __start,new Date()

                if not err and body?.indexOf expectString > -1
                    result.push "[ TEST    PASSED #{__end} ] #{target}"
                else result.push "[ TEST #FAILED #{__end} ] #{target}"

                callback null, result if i is options.length

    @getCurrentVersion = (options,callback=->)->
        exec "git fetch --tags && git tag",(a,b,c)->

            tags = b.split('\n')
            # remove invalid versions, otherwise semver throws an error
            tags[key] = "v0.0.0" for version,key in tags when not semver.valid version
            tags        = tags.sort semver.compare
            version = tags.pop()



            callback null,version

    @getNextVersion = (options, callback)->
        type = options.versiontype or "patch"
        Deploy.getCurrentVersion {},(err,version)->
            log "current version is #{version}"
            callback null, "v"+semver.inc(version,type)


module.exports = {Deploy, Release, AWS, cf, cloudformation}

