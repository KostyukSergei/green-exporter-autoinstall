Optional offline packages for Windows Server 2008 R2 (LHM / PowerShell 5.1 only).

These files are not in the git repository: the .NET installer is larger than
GitHub's 100 MB file limit, and Microsoft distributes them itself.
fetch-windows-assets.ps1 does not download them. Put the files in this folder
yourself when the host has no PowerShell 5.1:

  NDP48-x86-x64-AllOS-ENU.exe       .NET Framework 4.8 offline installer
    https://dotnet.microsoft.com/download/dotnet-framework/net48
    https://go.microsoft.com/fwlink/?linkid=2088631

  Win7AndW2K8R2-KB3191566-x64.msu   WMF 5.1 (KB3191566) for Server 2008 R2 / Windows 7
    https://www.microsoft.com/download/details.aspx?id=54616

bootstrap-prereqs.ps1 also accepts NDP472*.exe and any *KB3191566*.msu.

Not needed for windows_exporter alone (install-windows.cmd step 1).
