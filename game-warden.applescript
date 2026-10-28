-- Script to limit game usage to a certain number of hours per day and week
-- For the reference on AppleScript, see https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/introduction/ASLR_intro.html#//apple_ref/doc/uid/TP40000983-CH208-SW1

use framework "Foundation"
use framework "AppKit"
use scripting additions

-- log levels - setup by setupLogging()
property nsLogLevels        : missing value
-- defaults can be overridden using the environment variable GW_LOG_LEVEL
property currentLogLevel    : missing value

property weeklyUsageLimit   : missing value
property dailyUsageLimit    : missing value
property secondsBeforeWarning : missing value

property plistPath          : missing value
property hasShownWarning    : false
property usageStateFile     : missing value
property warnMessage        : missing value

-- This needs delayed setting for a strange reason:
-- if I set the property here, it seems that "user domain" gets set to root, but only when installed as an agent, not
-- as a script running on the command line! Resulting error looks like:
-- execution error: mkdir: /private/var/root/Library: Permission denied (1)
property appDir             : missing value -- Otherwise: POSIX path of (path to application support folder from user domain) & "game-warden"

-- either stderr or file - stderr is mostly useful when developing, file for non-interactive work
-- can be overridden using the environment variable GW_APPENDER
property appender           : "file"

property warnAction         : missing value

-- Record to store usage state
-- Problems to keep an eye out for
-- 1. Day shifts: reset time and need to make sure a long session crossing midnight is not counted on the next day
-- 2. Week shifts: see above, but a long session crossing midnight _should_ be counted, just not if new week
--
-- Algo:
-- To not lose recorded time, save the state to file every X seconds, in case the script exits
-- current elapsed time is calculated based on start of session to avoid drift (as compared to incrementing using timers)
-- on the end of each session, add the recorded session time to the total for the day
script timeBookkeeping
    property dailySeconds : 0
    property weeklySeconds : 0
    property startOfCurrentSession : missing value
end script

on run argv
    -- Turns out the exit status of the shell scripts is not equal to the exit status of the AppleScript
    if (count of argv) < 1 then
        do shell script ">&2 echo 'Error: Missing required argument (path to config.plist)'; exit 100"
    else
        set plistPath to item 1 of argv
        do shell script "[ -e " & quoted form of plistPath & " ] || (echo 'No such file: " & plistPath & "' && exit 200)"
        main()
    end if
end run

on main()
    local currentUser, matchedProcess, activeProcessHasMatch, interval, saveInterval

    set appDir  to (POSIX path of (path to application support folder from user domain)) & "game-warden"
    setupLogging()
    infoLog("\
  ______   ______   ______   ______   ______   ______   ______   ______   ______   ______   ______\
 /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/\
\
\
 ._.    ________                         __      __                  .___                    ._.\
 | |   /  _____/_____    _____   ____   /  \\    /  \\_____ _______  __| _/____   ____         | |\
 |_|  /   \\  ___\\__  \\  /     \\_/ __ \\  \\   \\/\\/   /\\__  \\\\_  __ \\/ __ |/ __ \\ /    \\        |_|\
 |-|  \\    \\_\\  \\/ __ \\|  Y Y  \\  ___/   \\        /  / __ \\|  | \\/ /_/ \\  ___/|   |  \\       |-|\
 | |   \\______  (____  /__|_|  /\\___  >   \\__/\\  /  (____  /__|  \\____ |\\___  >___|  /       | |\
 |_|          \\/     \\/      \\/     \\/         \\/        \\/           \\/    \\/     \\/        |_|\
\
\
  ______   ______   ______   ______   ______   ______   ______   ______   ______   ______   ______\
 /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/  /_____/\
 ")

    set warnMessage to configWithDefault("customExitMessage", "Save and exit to avoid losing work.")
    set weeklyUsageLimit to timeToSeconds(configWithDefault("weeklyMax", "05:00") & ":00")
    updateDailyUsageLimit()
    set secondsBeforeWarning to timeToSeconds(configWithDefault("warnTime", "00:02:00"))
    set warnAction to configWithDefault("warnAction", missing value)
    set usageStateFile to userData("usage-state.dat")
    set currentUser to do shell script "whoami"
    debugLog("script running as user: " & currentUser)
    debugLog("appDir: " & appDir)
    debugLog("secondsBeforeWarning: " & secondsBeforeWarning)

    do shell script "mkdir -p " & quoted form of appDir

    set timeBookkeeping's startOfCurrentSession to missing value
    set patternRecords to readProcessPatterns(plistPath)

    infoLog("Loading saved records")
    loadTimeBookkeeping()
    debugLog("main: finished init .. starting main loop")

    repeat
        set activeProcessHasMatch to false

        if shouldQuit() then
            return
        end if

        traceLog("has shown warning: " & hasShownWarning)
        -- lsappinfo talks to LaunchServices directly, so no Automation/Accessibility permission is needed
        -- (unlike System Events). Output format: "pid"=1234
        local appName
        try
            set processId to (do shell script "lsappinfo info -only pid $(lsappinfo front) | cut -d= -f2") as integer
            set appName to do shell script "basename \"$(ps -p " & processId & " -o comm=)\""
            traceLog("appName: " & appName)
            traceLog("pid: " & processId)
        on error err
            -- e.g. no frontmost app (lsappinfo front returns "[ NULL ]")
            debugLog("Could not determine frontmost app: " & err)
            set processId to missing value
        end try

        if processId is not missing value then
            debugLog("Checking for process pattern")
            repeat with r in patternRecords
                traceLog("Key: " & (key of r) & " -> Pattern: " & (pattern of r))
                set pattern to pattern of r

                -- If the shell exits with a non-zero code, it did not find the process
                -- It will also throw an error, which we catch and ignore
                try
                    do shell script "ps -f " & processId & " | grep -E " & quoted form of pattern
                    set activeProcessHasMatch to true
                    debugLog("Matched on process pattern: " & pattern)
                    set matchedProcess to {name: appName, pid: processId, patternKey: key of r, pattern: pattern of r}
                    exit repeat
                end try
            end repeat
        end if

        if not activeProcessHasMatch then
            if timeBookkeeping's startOfCurrentSession is not missing value then
                infoLog("No monitored process in the foreground. Elapsed time: " & getCurrentSessionElapsed() )
            end if

            if hasStateChanged() then
                updateStateAtSessionEnd()
                saveTimeBookkeeping()
            end if
        else
            resetStateIfRequired()

            if timeBookkeeping's startOfCurrentSession is missing value then
                infoLog("Monitored process in the foreground: " & appName & " (pid=" & processId & ")")
                set timeBookkeeping's startOfCurrentSession to current date
            end if

            -- Save every few seconds
            set saveInterval to 5
            if totalDailySeconds() mod saveInterval = 0 then
                saveTimeBookkeeping()
            end if

            -- hard and brutal exit
            if totalDailySeconds() > (dailyUsageLimit+5) or totalWeeklySeconds() > (weeklyUsageLimit + 5) then
                try
                    infoLog("Killing the current process")
                    do shell script "kill " & processId

                    displayNotification(configWithDefault("killMessage", "Time's up!"))
                end try
            -- soft and graceful exit
            else if totalDailySeconds() > dailyUsageLimit or totalWeeklySeconds() > weeklyUsageLimit then
                gracefulExit(matchedProcess)
            else
                showWarningIfCloseToThreshold()
            end if
        end if

        set interval to 1.0
        delay interval
    end repeat
end main

on showWarningIfCloseToThreshold()
    if not hasShownWarning then

        traceLog("timeBookkeeping: daily=" & timeBookkeeping's dailySeconds & ", weekly=" & timeBookkeeping's weeklySeconds & ", session=" & (timeBookkeeping's startOfCurrentSession as string))
        traceLog("dailyUsageLimit= " & dailyUsageLimit)
        traceLog("weeklyUsageLimit= " & weeklyUsageLimit)

        if totalDailySeconds() > (dailyUsageLimit - secondsBeforeWarning) or totalWeeklySeconds() > (weeklyUsageLimit - secondsBeforeWarning) then
            infoLog("showing warning")
            set hasShownWarning to true

            # this is a non-blocking system message (typically displayed as a box appearing in the top-right corner)
            displayNotification(warnMessage)

            if warnAction is not missing value then
                do shell script warnAction
            end if

        end if
    end if
end showWarningIfCloseToThreshold

on displayNotification(msg)
    display notification msg with title configWithDefault("notificationTitle", "Game Warden")
end displayNotification

on readFileOrDefault(filePath, defaultValue)
    try
        return (do shell script "cat " & quoted form of filePath)
    on error err
        infoLog("Caught error trying to read file (" & filePath & "): " & err)
        writeFile(defaultValue, filePath, false)
        return defaultValue
    end try
end readFileOrDefault

on writeFile(textContent, filePath, append)
    if append is false then
        do shell script "echo " & quoted form of textContent & " > " & quoted form of filePath
    else
        do shell script "echo " & quoted form of textContent & " >> " & quoted form of filePath
    end if
end writeFile

-- Turns out there already is a built-in log(%s) function ...
-- AppleScript is context sensitive, so you need to prefix with 'my ' from within a 'tell' block
-- (yes, AppleScript is weird)
on doLog(textContent)
    set timestamp to do shell script "date +\"%Y-%m-%dT%H:%M:%S%z\""
    set logEntry to "[" & timestamp & "] " & textContent

    if appender is "file" then
        local logFile
        set logFile to userData("app.log")
        writeFile(logEntry, logFile, true)
    else if appender is "stderr" then
        log(logEntry)
    else
        error "Illegal appender (" & appender & "). Legal values: [file, stderr]"
    end if

end log

-- Usage can be negative ("-00:10:00") when extra time has been given (see extend-time.sh)
on timeToSeconds(timeString)
    set sign to 1
    if timeString starts with "-" then
        set sign to -1
        set timeString to text 2 thru -1 of timeString
    end if
    set AppleScript's text item delimiters to ":"
    set {hrs, mins, secs} to text items of timeString
    set AppleScript's text item delimiters to ""
    return sign * ((hrs as integer) * 3600 + (mins as integer) * 60 + (secs as integer))
end timeToSeconds

on secondsToTime(totalSecs)
    set prefix to ""
    if totalSecs < 0 then
        set prefix to "-"
        set totalSecs to -totalSecs
    end if
    set hrs to totalSecs div 3600
    set mins to (totalSecs mod 3600) div 60
    set secs to totalSecs mod 60
    return prefix & pad(hrs) & ":" & pad(mins) & ":" & pad(secs)
end secondsToTime

on pad(num)
    if num < 10 then
        return "0" & num
    end if
    return num as string
end pad

on formatDate(aDate)
    return ((year of aDate) as string) & pad(month of aDate as integer) & pad(day of aDate)
end formatDate

on configWithDefault(key, defaultValue)
    try
        return do shell script "/usr/libexec/PlistBuddy -c 'Print " & key & "' " & quoted form of plistPath
    on error err
        debugLog("Caught error: " & err)
        return defaultValue
    end try
end configWithDefault

on resetStateIfNewDayOrWeek()
    try
        set fileDateString to do shell script "stat -f %Sm -t %Y%m%d " & quoted form of usageStateFile
        set currentDateString to formatDate(current date)
        if fileDateString is not currentDateString then
            infoLog("Reset daily usage: " & fileDateString & " != " & currentDateString)
            set timeBookkeeping's dailySeconds to 0
            set timeBookkeeping's startOfCurrentSession to current date
            updateDailyUsageLimit()
            -- reset the flag so that we can show the warning again
            set hasShownWarning to false
        end if

        set fileWeekNumber to (do shell script "stat -f %Sm -t %W " & quoted form of usageStateFile) as integer
        set currentWeekNumber to (do shell script "date +%W") as integer
        if fileWeekNumber is not currentWeekNumber then
            infoLog("Reset weekly usage: Week " & fileWeekNumber & " != " & currentWeekNumber)
            set timeBookkeeping's weeklySeconds to 0
        end if
    on error err
        infoLog("Weekly reset error: " & err)
    end try
end resetStateIfNewDayOrWeek

on resetStateIfRequired()
    debugLog("Checking any state needs resetting")
    resetStateIfNewDayOrWeek()
end resetStateIfRequired

on saveTimeBookkeeping()
    local daily, weekly
    set daily to totalDailySeconds()
    set weekly to totalWeeklySeconds()
    traceLog("--> saveTimeBookkeeping")
    traceLog("totalDailySeconds: " & daily)
    traceLog("totalWeeklySeconds: " & weekly)
    set dailyTime to secondsToTime(daily)
    set weeklyTime to secondsToTime(weekly)
    set content to dailyTime & "," & weeklyTime
    writeFile(content, usageStateFile, false)
end saveTimeBookkeeping

on loadTimeBookkeeping()
    try
        set content to readFileOrDefault(usageStateFile, "00:00:00,00:00:00")
        set AppleScript's text item delimiters to ","
        set {daily, weekly} to text items of content
        set AppleScript's text item delimiters to ""
        set timeBookkeeping's dailySeconds to timeToSeconds(daily)
        set timeBookkeeping's weeklySeconds to timeToSeconds(weekly)
    on error err
        infoLog("Failed to load usage state: " & err)
        set timeBookkeeping's dailySeconds to 0
        set timeBookkeeping's weeklySeconds to 0
    end try
end loadTimeBookkeeping

on hasStateChanged()
    return timeBookkeeping's dailySeconds is not totalDailySeconds()
end hasStateChanged

on updateStateAtSessionEnd()
    traceLog("--> updateStateAtSessionEnd")
    traceLog("timeBookkeeping's dailySeconds: " & timeBookkeeping's dailySeconds)
    traceLog("totalDailySeconds: " & totalDailySeconds())
    set timeBookkeeping's dailySeconds to totalDailySeconds()
    set timeBookkeeping's weeklySeconds to totalWeeklySeconds()
    set timeBookkeeping's startOfCurrentSession to missing value
end updateStateAtSessionEnd

on getCurrentSessionElapsed()
    traceLog("--> getCurrentSessionElapsed")
    set sessionStart to timeBookkeeping's startOfCurrentSession
    traceLog("timeBookkeeping's startOfCurrentSession: " & sessionStart)

    if sessionStart is missing value then return 0

    return (current date) - sessionStart
end getCurrentSessionElapsed


on totalDailySeconds()
    return timeBookkeeping's dailySeconds + getCurrentSessionElapsed()
end totalDailySeconds

on totalWeeklySeconds()
    return timeBookkeeping's weeklySeconds + getCurrentSessionElapsed()
end totalWeeklySeconds

on processWithArgumentsMatchesPattern(pid, pattern)
    try
        do shell script "ps -f " & pid & " | grep -E " & quoted form of pattern
        return true
    end try
    return false
end processWithArgumentsMatchesPattern

on gracefulExit(matchedProcess)
    set graceSeconds to timeToSeconds(configWithDefault("exitGraceTime", "00:02:00"))
    set alertTitle to configWithDefault("timeoutTitle", "Time's up")
    set alertText to configWithDefault("timeoutMessage", "Save and exit. The game will close in {seconds} seconds.")
    set alertText to replaceText(alertText, "{seconds}", graceSeconds as text)

    infoLog("Time is up. Showing exit alert for " & graceSeconds & " seconds")
    set alertShownAt to current date
    -- An alert from osascript itself needs no permissions, unlike sending keystrokes via System Events
    activate
    display alert alertTitle message alertText giving up after graceSeconds

    -- Keep the promised grace period even if the alert was dismissed early,
    -- then kill directly instead of relying on the game still being in the foreground
    set remainingSeconds to graceSeconds - ((current date) - alertShownAt)
    if remainingSeconds > 0 then delay remainingSeconds

    try
        infoLog("Killing " & (name of matchedProcess) & " (pid=" & (pid of matchedProcess) & ")")
        do shell script "kill " & (pid of matchedProcess)
        displayNotification(configWithDefault("killMessage", "Time's up!"))
    end try
end gracefulExit

on replaceText(theText, searchStr, replaceStr)
    set AppleScript's text item delimiters to searchStr
    set parts to text items of theText
    set AppleScript's text item delimiters to replaceStr
    set res to parts as text
    set AppleScript's text item delimiters to ""
    return res
end replaceText

on shouldQuit()
    set uninstallFlag to userData(".uninstall")
    try
        set result to do shell script "test -f " & quoted form of uninstallFlag & " && echo yes || echo no"
        if result is "yes" then
            infoLog("🧹 Uninstall flag detected. Exiting.")
            do shell script "rm -f " & quoted form of uninstallFlag
            return true
        end if
    on error
        return false
    end try
    return false
end shouldQuit

-- Read the dictionary of key:pattern pairs
-- Relies on 'use framework "Foundation"' to load it as an NSArray
on readProcessPatterns(plistPath)
    set rootDict to current application's NSDictionary's dictionaryWithContentsOfFile:plistPath
    if rootDict = missing value then error "Could not read plist: " & plistPath

    set patternsDict to rootDict's objectForKey:"processPatterns"
    if patternsDict = missing value then return {}

    set keysArray to patternsDict's allKeys()
    set res to {}
    repeat with k in keysArray
        set kText to k as text
        set patternText to (patternsDict's objectForKey:k) as text
        set end of res to {key:kText, pattern:patternText}
    end repeat
    return res
end readProcessPatterns

on updateDailyUsageLimit()
    traceLog("--> updateDailyUsageLimit")
    -- Ensure English days of the week to match the .plist keys.
    set currentDay to do shell script "LC_ALL=en_US.UTF-8 date +%A"
    set dailyUsageLimit to timeToSeconds(configWithDefault(currentDay, "01:00") & ":00")
    debugLog("daily usage limit for " & currentDay & ": " & dailyUsageLimit)
end updateDailyUsageLimit

on userData(someFile)
    return appDir & "/data/" & someFile
end userData

--------------------------------------------------------------------------------
-- Start logging code --
--------------------------------------------------------------------------------

on setupLogging()
    local lvlStr, appenderStr

    set nsLogLevels to current application's NSMutableDictionary's dictionary()
    nsLogLevels's setObject:0 forKey:"TRACE"
    nsLogLevels's setObject:1 forKey:"DEBUG"
    nsLogLevels's setObject:2 forKey:"INFO"
    nsLogLevels's setObject:3 forKey:"WARN"

    try
        set env to current application's NSProcessInfo's processInfo()'s environment()
        set lvlStr to env's objectForKey:"GW_LOG_LEVEL"
        if lvlStr is missing value then
            set currentLogLevel to levelFromText("INFO")
        else
            set currentLogLevel to levelFromText(lvlStr as text)
        end if

        set appenderStr to env's objectForKey:"GW_APPENDER"
        if appenderStr is not missing value then
            set appender to appenderStr as text
        end if

    end try

    traceLog(appenderStr as text)
    traceLog(lvlStr as text)
    traceLog(currentLogLevel)
    traceLog("logging setup finished")
end setupLogging

-- dynamic lookup
on levelFromText(keyStr)
    set val to nsLogLevels's objectForKey:keyStr
    if val is missing value then
        error "Was passed invalid log level: " & keyStr
    end if

    return val as integer
end levelFromText

on infoLog(textContent)
    if currentLogLevel <= levelFromText("INFO") then
        doLog("INFO : " & textContent)
    end if
end log

on debugLog(textContent)
    if currentLogLevel <= levelFromText("DEBUG") then
        doLog("DEBUG: " & textContent)
    end if
end debugLog

on traceLog(textContent)
    if currentLogLevel <= levelFromText("TRACE") then
        doLog("TRACE: " & textContent)
    end if
end traceLog

--------------------------------------------------------------------------------
-- End logging code --
--------------------------------------------------------------------------------
