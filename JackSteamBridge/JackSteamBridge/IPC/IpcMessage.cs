using System.Text.Json;
using System.Text.Json.Serialization;

namespace JackSteamBridge.IPC;

public class IpcRequest
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("command")]
    public string Command { get; set; } = "";

    [JsonPropertyName("params")]
    public JsonElement? Params { get; set; }
}

public class IpcResponse
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("success")]
    public bool Success { get; set; }

    [JsonPropertyName("data")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public object? Data { get; set; }

    [JsonPropertyName("error")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Error { get; set; }

    [JsonPropertyName("event")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Event { get; set; }

    public static IpcResponse Ok(string id, object? data = null) =>
        new() { Id = id, Success = true, Data = data };

    public static IpcResponse Fail(string id, string error) =>
        new() { Id = id, Success = false, Error = error };

    public static IpcResponse EventMsg(string eventName, object? data = null) =>
        new() { Id = null, Success = true, Event = eventName, Data = data };
}
