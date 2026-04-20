# Cleanup old aws resources

Here is how users can clean up old aws resources periodically.

The general method is to use a CronJob to trigger a Task that deletes old aws resources that are not protected by aws-nuke config. 

## Prerequisites

* A Kubernetes cluster with Tekton Pipelines installed
* Several old aws resources you wish to delete

## Scheduling the cleanup job

You'll need to install all the files in this directory to run the cleanup task.


* [cleanup-template.yaml](cleanup-template.yaml): this creates the TriggerTemplate that spawns the TaskRun that does the deleting. It uses the `aws-nuke` CLI to do the deleting. 

* [binding.yaml](binding.yaml): this creates the TriggerBinding that is used to pass parameters to the TaskRun. There are two parameters that are passed by this.
    - `aws-nuke-s3-config-path`: this holds the aws-nuke config s3 path. The config holds the resources that needs to be retained by the sweeper job. For instructions on building a aws-nuke config, refer to this https://github.com/rebuy-de/aws-nuke
    - `aws-account-alias`: aws-nuke requires account alias for confirmation before deleting. Here is how the account alias can be setup. https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-alias.html

* [eventlistener.yaml](eventlistener.yaml): this creates the sink that receives the incoming event that triggers the creation of the cleanup job.

* [cronjob.yaml](cronjob.yaml): this is used to run the cleanup job on a schedule. The schedule for the job running can be set in the `.spec.schedule` field using [crontab format](https://crontab.guru/)