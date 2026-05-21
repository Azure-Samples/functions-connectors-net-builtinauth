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
// telemetry stays correlated. The exporter reads APPLICATIONINSIGHTS_CONNECTION_STRING
// from app settings automatically; locally it's a no-op when unset.
builder.Services.AddOpenTelemetry()
    .UseFunctionsWorkerDefaults()
    .UseAzureMonitorExporter();

builder.Build().Run();
