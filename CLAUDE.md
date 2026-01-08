# Project Instructions for Claude

## PowerShell Coding Standards

### Function Naming Convention
- all custom functions must comply with the Verb-SPVidComp-Noun naming convention
- All custom functions, even those that are only used internally, must follow the `{Verb}-SPVidComp{Noun}` naming convention in order to prevent name collisions with existing cmdlets and functions from other PowerShell scripts and modules.

## Logging Architecture
- All logs should be written to the SQLite database, not log files.
- The only exception to this rule is if there is an error with the database itself, in which case, those error messages should be written to an error log file and the user should be told where to find it.
