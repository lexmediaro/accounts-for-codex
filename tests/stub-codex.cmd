@echo off
rem Stands in for a native Codex CLI in the Windows test: records the account folder and the arguments.
>>"%STUB_CODEX_LOG%" echo NATIVE home=[%CODEX_HOME%] args=[%*]
exit /b 0
