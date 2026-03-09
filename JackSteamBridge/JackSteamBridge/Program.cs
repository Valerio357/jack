using JackSteamBridge.IPC;
using JackSteamBridge.Steam;

IpcServer.Log("JackSteamBridge starting...");

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

var ipc = new IpcServer();
var steam = new SteamManager(ipc);

// Ping handler for health checks
ipc.RegisterHandler("ping", _ => Task.FromResult<object?>(new { pong = true }));

// Start the SteamKit2 callback pump
steam.StartCallbackLoop();

IpcServer.Log("Ready. Listening for commands on stdin...");

// Run the IPC loop (blocks until stdin closes or cancellation)
await ipc.RunAsync(cts.Token);

steam.Stop();
IpcServer.Log("Shutting down.");
