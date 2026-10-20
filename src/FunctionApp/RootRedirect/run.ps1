# Project-Version: 1.4.20261020.7
# Author: andreas.lucas@outlook.com (aka Kili)

using namespace System.Net

param($Request, $TriggerMetadata)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::Found
    Headers = @{
        Location = '/api/ui/index.html'
        'Cache-Control' = 'no-store'
        'Referrer-Policy' = 'no-referrer'
        'X-Content-Type-Options' = 'nosniff'
    }
    Body = 'Redirecting to the Autopilot Import web frontend.'
})
