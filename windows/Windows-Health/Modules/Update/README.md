# Update module

Modes: Check, Install, Reboot, Cleanup.

Cleanup separates locked/protected `Skipped` files from real `Errors`.

Optional host-local rules use `Config\ExtraCleanup.txt`:

`Path|MinFileSizeMB|Recursive`

Example:

`C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp|1024|false`

The real `ExtraCleanup.txt` is ignored by Git. See `ExtraCleanup.example.txt`.
