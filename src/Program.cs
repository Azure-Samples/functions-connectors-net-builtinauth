using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// OpenTelemetry -> Azure Monitor (App Insights) for the worker process.
// Paired with `"telemetryMode": "OpenTelemetry"` in host.json so host + worker
// telemetry stays correlated.
//
// The App Insights resource is provisioned with `disableLocalAuth: true`, so the
// exporter must authenticate via AAD using the same user-assigned managed identity
// the function app uses (its client id is in AZURE_CLIENT_ID, set by bicep).
// Without the credential, the exporter falls back to iKey-only auth and AI silently
// 401s every worker log/trace export — host-side telemetry (requests) still shows
// up because the host uses APPLICATIONINSIGHTS_AUTHENTICATION_STRING.
// Locally APPLICATIONINSIGHTS_CONNECTION_STRING is unset and this whole block no-ops.
var applicationInsightsConnectionString = Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING");
var openTelemetry = builder.Services.AddOpenTelemetry()
    .UseFunctionsWorkerDefaults();

if (!string.IsNullOrWhiteSpace(applicationInsightsConnectionString))
{
    var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
    {
        ManagedIdentityClientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")
    });

    openTelemetry.UseAzureMonitorExporter(o =>
    {
        o.ConnectionString = applicationInsightsConnectionString;
        o.Credential = credential;
    });
}

builder.Build().Run();
