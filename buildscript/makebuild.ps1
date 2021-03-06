################################################
# Get latest from TFS
# Build using devenv
# Run mstests (Optional)
# Check for build failure and send email notification
# to the committers of the last n checkins (n=5)
################################################
# config section  - copy to makebuild_config.ps1 and change
$BASEDIR="C:\temp\test\"

# Visual Studio environment bat file
$VS_ENVVARS="C:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\Tools\vsvars32.bat"

# the solution file (relative to TFS_PROJECT_DIR)
$TFS_SERVER="http://tfsserver:8080"

# the root dir of your entire solution on the TFS server
$TFS_PROJECT_DIR='$/TopSolutionDir'

# the solution file to build (relative to TFS_PROJECT_DIR)
$SLNFILE="Relative\Path\To\SolutionFile.sln"
#$TESTCONTAINER="MyApp.Test\bin\Debug\App.Test.dll" 

$MAILSENDER="owner@buildserver.com"
$MAILRECIPIENTS=@( 
    $MAILSENDER ,
    "project@manager.com"
)
$SMTPSERVER='smtp.mycompany.com'

# ADDOMAIN in TFS' committer property will be replaced
# with MAILDOMAIN for recipient email generation
$ADDOMAIN='DEVELOPERS'
$MAILDOMAIN='company.com'

# end config
################################################

### Get configuration
$SCRIPTNAME=$MyInvocation.MyCommand
$CONFIGNAME="$SCRIPTNAME".split(".")[0] + "_config.ps1"
$CONFIGFILE=(split-path -Path ($MyInvocation.InvocationName)) + "\$CONFIGNAME"

if( -not (test-path $CONFIGFILE ))
{
    return "Could not read config from $CONFIGFILE. Exiting."
}
. $CONFIGFILE


$TSTAMP=get-date -Format yyyy-MM-dd_HH-mm-ss

$TESTNAME="tfstest." + $TSTAMP
$WORKDIR=$BASEDIR + $TESTNAME
$LOG=$BASEDIR + $TESTNAME + ".log"
if( test-path $LOG ) { rm -Force $LOG }

## Prepare environment for devenv
## should be automated/dynamic so it can find whatever VS install there is
cmd /c "echo off & `"$VS_ENVVARS`" & set" | 
Foreach-Object {
        $p, $v = $_.split('=')
        Set-Item -path env:$p -value $v
}


### work functions ###

function GetFromTFS()
{
    mkdir -Force $WORKDIR
    pushd $WORKDIR
    if($DEBUG) { write-host "Getting source from TFS (cwd=$(pwd))" }
    tf workspace /new /noprompt /server:$TFS_SERVER $TESTNAME 
    tf workfold /map /server:$TFS_SERVER /workspace:$TESTNAME $TFS_PROJECT_DIR $WORKDIR
    tf get /recursive /force /noprompt $TFS_PROJECT_DIR 
    popd
}

function CleanUp()
{
    pushd $BASEDIR
    if($DEBUG) { write-host "Cleaning up mess (cwd=$(pwd))"  }
    tf workfold /unmap /workspace:$TESTNAME $WORKDIR
    tf workspace /delete /noprompt $TESTNAME
    rmdir -recurse -force $WORKDIR
    popd
}

function BuildSolution()
{
    pushd $WORKDIR
    if($DEBUG) { write-host "Starting build process (cwd=$(pwd))" }
    msbuild $SLNFILE /target:build /noconsolelogger /maxcpucount  #HACK: build twice to work around sharepoint project pre build event being fubar
    msbuild $SLNFILE /target:clean /noconsolelogger /maxcpucount  #clean so next build doesn't have to be a rebuild
    msbuild $SLNFILE /target:build /filelogger /fileloggerparameters:"verbosity=normal;LogFile=$LOG" /maxcpucount
    #select-string $LOG -pattern "^Build" | write-host 
    popd
}

function RunTests()
{
    if( $TESTCONTAINER )
    {
        pushd $WORKDIR
        if($DEBUG) { write-host "Running tests (cwd=$(pwd))" }
        mstest /testcontainer:$TESTCONTAINER 2>&1 >> $LOG
        #select-string $LOG -pattern "^Summary" -Context 0,10 | write-host 
        popd
    }
}

function GetTfs( [string] $serverName )
{
    # load the required dll
    [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")

    $propertiesToAdd = (
        ('VCS', 'Microsoft.TeamFoundation.VersionControl.Client', 'Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer'),
        ('WIT', 'Microsoft.TeamFoundation.WorkItemTracking.Client', 'Microsoft.TeamFoundation.WorkItemTracking.Client.WorkItemStore'),
        ('CSS', 'Microsoft.TeamFoundation', 'Microsoft.TeamFoundation.Server.ICommonStructureService'),
        ('GSS', 'Microsoft.TeamFoundation', 'Microsoft.TeamFoundation.Server.IGroupSecurityService')
    )

    # fetch the TFS instance, but add some useful properties to make life easier
    # Make sure to "promote" it to a psobject now to make later modification easier
    [psobject] $tfs = [Microsoft.TeamFoundation.Client.TeamFoundationServerFactory]::GetServer($serverName)
    foreach ($entry in $propertiesToAdd) {
        $scriptBlock = '
            [System.Reflection.Assembly]::LoadWithPartialName("{0}") > $null
            $this.GetService([{1}])
        ' -f $entry[1],$entry[2]
        $tfs | add-member scriptproperty $entry[0] $ExecutionContext.InvokeCommand.NewScriptBlock($scriptBlock)
    }
    return $tfs
}

function TFSChangesInPeriod( [DateTime] $fromDate, [DateTime] $toDate  )
{
    $tfs = GetTfs $TFS_SERVER
    #grrr!?! Load more dll's 
    $assemblies = @( 'Microsoft.TeamFoundation.VersionControl.Client', 
                    'Microsoft.TeamFoundation.WorkItemTracking.Client', 
                    'Microsoft.TeamFoundation',
                    'Microsoft.TeamFoundation.Client' )
    foreach( $a in $assemblies) { [void][System.Reflection.Assembly]::LoadWithPartialName($a) }
    
    #$versionLatest = [Microsoft.TeamFoundation.VersionControl.Client.VersionSpec].Latest
    $versionLatest = new-object Microsoft.TeamFoundation.VersionControl.Client.DateVersionSpec $toDate
    $versionFirst = new-object Microsoft.TeamFoundation.VersionControl.Client.DateVersionSpec $fromDate
    $deletionId = 0
    $recursionType = [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::Full
    $user = ""
    $maxChangesets = 5
    $includeChanges = $false
    $changesets=$tfs.vcs.QueryHistory( $TFS_PROJECT_DIR, 
                       $versionLatest,
                        $deletionId,
                        $recursionType,
                        $user,
                        $versionFirst,
                        $versionLatest,
                        $maxChangesets,
                        $includeChanges,
                        $true )
    return $changesets
}


# check the latest version in TFS and only build if it's newer than previous build
$now=$(get-date)
$earlier = $now.AddDays(-10)
$tfschanges=TFSChangesInPeriod $earlier $now
$VERSIONFILE="$BASEDIR" + "buildscript_latest_changeset.tmp"
$latest = ($tfschanges | select-object -first 1).ChangesetId
if(test-path $VERSIONFILE ) 
{
    $previous = get-content $VERSIONFILE
    if($latest -eq $previous -and $false) #DEBUG
    {
        return "No new changes since $latest ($VERSIONFILE)"
    }
}
$latest | write-output > $VERSIONFILE


# OK, check out latest version, build and report if errors occur
pushd $BASEDIR
$null = GetFromTFS
BuildSolution
RunTests

$linenumber = Select-String $LOG -pattern "Build Failed" | Select-Object Linenumber

if($linenumber) # broken build
{
    $smtp = New-Object System.Net.Mail.SMTPClient -ArgumentList $SMTPSERVER
    $msg = New-Object System.Net.Mail.MailMessage
    $msg.BodyEncoding = [System.Text.Encoding]::UTF8
    $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
    $msg.IsBodyHtml = False
    $msg.Subject = "Build failed: $SLNFILE"
    $msg.From = $MAILSENDER

    $msg.Body = "Build failed. `nLast checkins below. `nSee attached log for build details."
    $msg.Body = $msg.Body + "`nYou get this mail because you are among the latest committers`n" 
    $tfschanges | foreach-object { 
            $line = $_.Committer + " checked in at " + $_.CreationDate
            $msg.Body = $msg.Body + "`n$line" 
        } 
   
    # add the latest committers to the mail recipient list
    $tfschanges | foreach-object {
        $MAILRECIPIENTS += $_.Committer -replace (("$ADDOMAIN"+'\\(.*)'), ('$1@'+"$MAILDOMAIN")) 
    } 
    $MAILRECIPIENTS=@($MAILSENDER) #DEBUG, disable spamming
    foreach( $r in $($MAILRECIPIENTS |where-object { -not( $_ -eq "") } | sort-object -unique ) ) 
    {
            [void]$msg.To.Add( $r )
    }
    
    $attachment = New-Object System.Net.Mail.Attachment –ArgumentList $LOG, ‘text/plain’
    $msg.Attachments.Add($attachment)
    $smtp.Send( $msg )
    write-host "Build failed"
}
else
{
    write-host "Build OK"
    $null = CleanUp
}

popd