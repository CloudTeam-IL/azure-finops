## These scripts are for backing up and deleting unattached disks.
- TagUnAttachedDisk is for tagging the disk that are unattached for x days for delete.
- DeleteTaggedDisks is for snapshoting the tagged disks and then deleting these disks.
- DeleteOldSnapshots is for deleting snapshot that created x days ago.
- the arm template requires a parameter for the automation account that the scripts are going to be deployed at.
