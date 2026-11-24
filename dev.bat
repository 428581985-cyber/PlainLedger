@echo off
REM PlainLedger dev launcher - double click to start hot reload session
REM Environment is set here because system PATH still points to Flutter 3.27.3.

set JAVA_HOME=C:\Users\Gordo\AppData\Local\jdk-17
set ANDROID_HOME=C:\Users\Gordo\AppData\Local\Android\Sdk
set ANDROID_SDK_ROOT=C:\Users\Gordo\AppData\Local\Android\Sdk
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
set HTTP_PROXY=http://127.0.0.1:7897
set HTTPS_PROXY=http://127.0.0.1:7897
set NO_PROXY=localhost,127.0.0.1,.aliyun.com,.flutter-io.cn
set PATH=%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%PATH%
set ADB=%ANDROID_HOME%\platform-tools\adb.exe

cd /d %~dp0

echo.
echo  PlainLedger dev session
echo  ----------------------------------------
echo  r  = hot reload    (keep state, ~1s)
echo  R  = hot restart   (reset state)
echo  q  = quit  (screen timeout restored on exit)
echo  ----------------------------------------
echo.

REM Keep the screen awake only while this session runs (2 = USB only).
REM Normal charging behaviour is restored after 'q'.
"%ADB%" shell settings put global stay_on_while_plugged_in 2 >nul 2>&1

"C:\Users\Gordo\AppData\Local\flutter-3.47.9\bin\flutter.bat" run --no-pub --flavor dev -d AS6VVB6323004666

REM Restore normal screen timeout so daily charging does not keep the screen on.
"%ADB%" shell settings put global stay_on_while_plugged_in 0 >nul 2>&1
echo.
echo  Screen timeout restored to normal.
echo.

pause
