# Project Instructions for Claude

## Memory Management

### Automatic Memory Updates
- When a user message starts with "#", treat the content as an instruction to update project memory
- Automatically update this CLAUDE.md file with the insight/instruction provided
- Do not ask for confirmation - just update the file and acknowledge the change
- This allows the user to quickly persist important learnings and preferences

## Working Philosophy

### Think Critically Before Implementing
- When the user suggests a solution or approach, PAUSE and consider if there are simpler/cleaner/faster alternatives
- Ask yourself: "Is this the best way to accomplish the goal, or is there another technique they haven't thought of yet?"
- If a better alternative exists, present it to the user with your reasoning BEFORE implementing anything
- The user's first idea is rarely their best idea - help them find better solutions through critical analysis
- Only implement after discussing alternatives and getting confirmation

**Example**: User suggests using ffprobe to check file completion → Recognize that checking file locks is simpler/faster → Suggest file lock approach first

## PowerShell Coding Standards

### Function Naming Convention
- all custom functions must comply with the Verb-SPVidComp-Noun naming convention
- All custom functions, even those that are only used internally, must follow the `{Verb}-SPVidComp{Noun}` naming convention in order to prevent name collisions with existing cmdlets and functions from other PowerShell scripts and modules.

## Logging Architecture
- All logs should be written to the SQLite database, not log files.
- The only exception to this rule is if there is an error with the database itself, in which case, those error messages should be written to an error log file and the user should be told where to find it.
