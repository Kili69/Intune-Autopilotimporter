# Project-Version: 1.0.20260812.2
# Author: andreas.lucas@microsoft.com (aka Kili)
# Azure Functions PowerShell managed dependencies.
#
# Az.Accounts provides managed-identity authentication in profile.ps1 and
# Microsoft Graph access-token acquisition in ImportDevice/run.ps1. The
# Functions host installs a compatible 4.x release during application startup.
@{
    'Az.Accounts' = '4.*'
}