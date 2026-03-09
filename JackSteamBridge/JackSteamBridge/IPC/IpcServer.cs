using System.Text.Json;

namespace JackSteamBridge.IPC;

/// <summary>
/// Reads JSON-RPC requests from stdin, dispatches to handlers, writes responses to stdout.
/// Stderr is used for logging only.
/// </summary>
public class IpcServer
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly Dictionary<string, Func<JsonElement?, Task<object?>>> _handlers = new();
    private readonly object _writeLock = new();

    public void RegisterHandler(string command, Func<JsonElement?, Task<object?>> handler)
    {
        _handlers[command] = handler;
    }

    /// <summary>Send an unsolicited event to the Swift side.</summary>
    public void SendEvent(string eventName, object? data = null)
    {
        var msg = IpcResponse.EventMsg(eventName, data);
        WriteLine(msg);
    }

    public async Task RunAsync(CancellationToken ct)
    {
        using var reader = new StreamReader(Console.OpenStandardInput());

        while (!ct.IsCancellationRequested)
        {
            string? line;
            try
            {
                line = await reader.ReadLineAsync(ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            if (line == null) break; // stdin closed
            if (string.IsNullOrWhiteSpace(line)) continue;

            IpcRequest? request;
            try
            {
                request = JsonSerializer.Deserialize<IpcRequest>(line, JsonOpts);
            }
            catch
            {
                Log($"Invalid JSON: {line}");
                continue;
            }

            if (request == null || string.IsNullOrEmpty(request.Command))
            {
                Log($"Invalid request: {line}");
                continue;
            }

            // Dispatch
            _ = Task.Run(async () =>
            {
                try
                {
                    if (request.Command == "shutdown")
                    {
                        WriteLine(IpcResponse.Ok(request.Id));
                        Environment.Exit(0);
                        return;
                    }

                    if (!_handlers.TryGetValue(request.Command, out var handler))
                    {
                        WriteLine(IpcResponse.Fail(request.Id, $"Unknown command: {request.Command}"));
                        return;
                    }

                    var result = await handler(request.Params);
                    WriteLine(IpcResponse.Ok(request.Id, result));
                }
                catch (Exception ex)
                {
                    Log($"Error handling '{request.Command}': {ex.Message}");
                    WriteLine(IpcResponse.Fail(request.Id, ex.Message));
                }
            }, ct);
        }
    }

    private void WriteLine(IpcResponse response)
    {
        var json = JsonSerializer.Serialize(response, JsonOpts);
        lock (_writeLock)
        {
            Console.Out.WriteLine(json);
            Console.Out.Flush();
        }
    }

    private static readonly StreamWriter? _logFile;
    static IpcServer()
    {
        try { _logFile = new StreamWriter("/tmp/jackbridge.log", append: true) { AutoFlush = true }; }
        catch { }
    }

    public static void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] {message}";
        Console.Error.WriteLine($"[JackSteamBridge] {message}");
        Console.Error.Flush();
        _logFile?.WriteLine(line);
    }
}
