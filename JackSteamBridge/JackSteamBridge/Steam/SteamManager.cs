using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.Internal;
using JackSteamBridge.IPC;

namespace JackSteamBridge.Steam;

/// <summary>
/// Manages the SteamKit2 client lifecycle: connect, authenticate, callbacks.
/// Exposes IPC command handlers for the Swift bridge.
/// </summary>
public class SteamManager
{
    private readonly SteamClient _client;
    private readonly CallbackManager _callbackManager;
    private readonly SteamUser _steamUser;
    private readonly SteamApps _steamApps;
    private readonly SteamUnifiedMessages _unifiedMessages;
    private readonly IpcServer _ipc;

    private readonly CancellationTokenSource _cts = new();
    private TaskCompletionSource<bool>? _connectTcs;
    private bool _isRunning;

    // Session state
    public bool IsLoggedOn { get; private set; }
    public SteamID? SteamID { get; private set; }
    public string AccountName { get; private set; } = "";
    public string? RefreshToken { get; private set; }
    public string? AccessToken { get; private set; }

    // Auth session for multi-step login
    private CredentialsAuthSession? _credAuthSession;
    private QrAuthSession? _qrAuthSession;

    public SteamManager(IpcServer ipc)
    {
        _ipc = ipc;
        var config = SteamConfiguration.Create(b =>
            b.WithConnectionTimeout(TimeSpan.FromSeconds(60))
        );
        _client = new SteamClient(config);
        _callbackManager = new CallbackManager(_client);

        _steamUser = _client.GetHandler<SteamUser>()!;
        _steamApps = _client.GetHandler<SteamApps>()!;
        _unifiedMessages = _client.GetHandler<SteamUnifiedMessages>()!;

        // Register callbacks
        _callbackManager.Subscribe<SteamClient.ConnectedCallback>(OnConnected);
        _callbackManager.Subscribe<SteamClient.DisconnectedCallback>(OnDisconnected);
        _callbackManager.Subscribe<SteamUser.LoggedOnCallback>(OnLoggedOn);
        _callbackManager.Subscribe<SteamUser.LoggedOffCallback>(OnLoggedOff);
        _callbackManager.Subscribe<SteamApps.LicenseListCallback>(OnLicenseList);

        RegisterCommands();
    }

    private void RegisterCommands()
    {
        _ipc.RegisterHandler("connect", HandleConnect);
        _ipc.RegisterHandler("login", HandleLogin);
        _ipc.RegisterHandler("loginQR", HandleLoginQR);
        _ipc.RegisterHandler("loginWithToken", HandleLoginWithToken);
        _ipc.RegisterHandler("submitGuardCode", HandleSubmitGuardCode);
        _ipc.RegisterHandler("getSessionInfo", HandleGetSessionInfo);
        _ipc.RegisterHandler("getOwnedApps", HandleGetOwnedApps);
        _ipc.RegisterHandler("cloudEnumerate", HandleCloudEnumerate);
        _ipc.RegisterHandler("cloudChangelist", HandleCloudGetChangelist);
        _ipc.RegisterHandler("cloudUpload", HandleCloudUpload);
        _ipc.RegisterHandler("getAccessToken", HandleGetAccessToken);
        _ipc.RegisterHandler("disconnect", HandleDisconnect);
    }

    /// <summary>Start the callback pump loop.</summary>
    public void StartCallbackLoop()
    {
        _isRunning = true;
        Task.Run(() =>
        {
            while (_isRunning)
            {
                _callbackManager.RunWaitCallbacks(TimeSpan.FromMilliseconds(250));
            }
        });
    }

    public void Stop()
    {
        _isRunning = false;
        _client.Disconnect();
        _cts.Cancel();
    }

    // ──────────────────────────────────────────────
    // IPC Command Handlers
    // ──────────────────────────────────────────────

    private async Task<object?> HandleConnect(JsonElement? _)
    {
        if (_client.IsConnected)
            return new { connected = true };

        _connectTcs = new TaskCompletionSource<bool>();
        _client.Connect();

        var connected = await _connectTcs.Task;
        return new { connected };
    }

    private async Task<object?> HandleLogin(JsonElement? p)
    {
        var accountName = p?.GetProperty("accountName").GetString() ?? "";
        var password = p?.GetProperty("password").GetString() ?? "";
        var guardData = p?.TryGetProperty("guardData", out var gd) == true ? gd.GetString() : null;

        if (!_client.IsConnected)
        {
            _connectTcs = new TaskCompletionSource<bool>();
            _client.Connect();
            await _connectTcs.Task;
        }

        IpcServer.Log($"Starting credentials auth for '{accountName}'...");

        _credAuthSession = await _client.Authentication.BeginAuthSessionViaCredentialsAsync(
            new AuthSessionDetails
            {
                Username = accountName,
                Password = password,
                IsPersistentSession = true,
                GuardData = guardData,
                Authenticator = new BridgeAuthenticator(_ipc),
            });

        var pollResponse = await _credAuthSession.PollingWaitForResultAsync();

        // Log on with the refresh token
        _steamUser.LogOn(new SteamUser.LogOnDetails
        {
            Username = pollResponse.AccountName,
            AccessToken = pollResponse.RefreshToken,
            ShouldRememberPassword = true,
        });

        AccountName = pollResponse.AccountName;
        RefreshToken = pollResponse.RefreshToken;
        AccessToken = pollResponse.AccessToken;

        // Wait for LoggedOn callback
        var loggedOn = await WaitForLogOn();

        return new
        {
            steamID64 = SteamID?.ConvertToUInt64().ToString() ?? "",
            accountName = AccountName,
            accessToken = AccessToken,
            refreshToken = RefreshToken,
            success = loggedOn
        };
    }

    private async Task<object?> HandleLoginQR(JsonElement? p)
    {
        if (!_client.IsConnected)
        {
            _connectTcs = new TaskCompletionSource<bool>();
            _client.Connect();
            await _connectTcs.Task;
        }

        _qrAuthSession = await _client.Authentication.BeginAuthSessionViaQRAsync(
            new AuthSessionDetails());

        // Notify Swift of URL changes
        _qrAuthSession.ChallengeURLChanged = () =>
        {
            _ipc.SendEvent("qrChallengeURLChanged", new { url = _qrAuthSession.ChallengeURL });
        };

        var challengeURL = _qrAuthSession.ChallengeURL;

        // Start polling in background
        _ = Task.Run(async () =>
        {
            try
            {
                var pollResponse = await _qrAuthSession.PollingWaitForResultAsync();

                _steamUser.LogOn(new SteamUser.LogOnDetails
                {
                    Username = pollResponse.AccountName,
                    AccessToken = pollResponse.RefreshToken,
                    ShouldRememberPassword = true,
                });

                AccountName = pollResponse.AccountName;
                RefreshToken = pollResponse.RefreshToken;
                AccessToken = pollResponse.AccessToken;

                var loggedOn = await WaitForLogOn();

                _ipc.SendEvent("loginResult", new
                {
                    success = loggedOn,
                    steamID64 = SteamID?.ConvertToUInt64().ToString() ?? "",
                    accountName = AccountName,
                    accessToken = AccessToken,
                    refreshToken = RefreshToken,
                });
            }
            catch (Exception ex)
            {
                _ipc.SendEvent("loginResult", new { success = false, error = ex.Message });
            }
        });

        return new { challengeURL };
    }

    private async Task<object?> HandleLoginWithToken(JsonElement? p)
    {
        var accountName = p?.GetProperty("accountName").GetString() ?? "";
        var refreshToken = p?.GetProperty("refreshToken").GetString() ?? "";

        IpcServer.Log($"Token login for '{accountName}', token length={refreshToken.Length}");

        // Connect if not already connected
        if (!_client.IsConnected)
        {
            _connectTcs = new TaskCompletionSource<bool>();
            _client.Connect();
        }
        else
        {
            _connectTcs = new TaskCompletionSource<bool>();
            _connectTcs.TrySetResult(true);
        }
        var connected = await _connectTcs.Task;
        if (!connected)
            return new { success = false, error = "Failed to connect to Steam" };

        AccountName = accountName;
        RefreshToken = refreshToken;

        // Try without username first (SteamKit2 3.x token-based login)
        _steamUser.LogOn(new SteamUser.LogOnDetails
        {
            Username = accountName,
            AccessToken = refreshToken,
        });

        var loggedOn = await WaitForLogOn();

        if (!loggedOn)
        {
            // Retry without username
            IpcServer.Log("Retrying token login without username...");
            if (!_client.IsConnected)
            {
                _connectTcs = new TaskCompletionSource<bool>();
                _client.Connect();
                await _connectTcs.Task;
            }

            _steamUser.LogOn(new SteamUser.LogOnDetails
            {
                AccessToken = refreshToken,
            });
            loggedOn = await WaitForLogOn();
        }

        return new
        {
            success = loggedOn,
            steamID64 = SteamID?.ConvertToUInt64().ToString() ?? "",
            accountName = AccountName,
        };
    }

    private Task<object?> HandleSubmitGuardCode(JsonElement? p)
    {
        // Guard code is handled via BridgeAuthenticator events
        // This is a placeholder — the authenticator flow handles it
        return Task.FromResult<object?>(new { success = true });
    }

    private Task<object?> HandleGetSessionInfo(JsonElement? _)
    {
        return Task.FromResult<object?>(new
        {
            isLoggedOn = IsLoggedOn,
            steamID64 = SteamID?.ConvertToUInt64().ToString() ?? "",
            accountName = AccountName,
        });
    }

    // License list cached from callback
    private List<uint> _ownedAppIDs = new();

    private Task<object?> HandleGetOwnedApps(JsonElement? _)
    {
        return Task.FromResult<object?>(new { appIDs = _ownedAppIDs });
    }

    private async Task EnsureLoggedIn(JsonElement? p)
    {
        if (IsLoggedOn && _client.IsConnected) return;

        var accountName = p?.TryGetProperty("accountName", out var an) == true ? an.GetString() : null;
        var refreshToken = p?.TryGetProperty("refreshToken", out var rt) == true ? rt.GetString() : null;
        var loginName = accountName ?? AccountName;
        var loginToken = refreshToken ?? RefreshToken;

        if (string.IsNullOrEmpty(loginName) || string.IsNullOrEmpty(loginToken))
            throw new InvalidOperationException("Not logged in and no credentials provided");

        if (!_client.IsConnected)
        {
            _connectTcs = new TaskCompletionSource<bool>();
            _client.Connect();
            if (!await _connectTcs.Task)
                throw new InvalidOperationException("Failed to connect to Steam");
        }

        if (!IsLoggedOn)
        {
            AccountName = loginName;
            RefreshToken = loginToken;
            _steamUser.LogOn(new SteamUser.LogOnDetails { Username = loginName, AccessToken = loginToken });
            if (!await WaitForLogOn())
                throw new InvalidOperationException("Token login failed");
        }
    }

    private async Task<object?> HandleCloudEnumerate(JsonElement? p)
    {
        var appId = p?.GetProperty("appID").GetUInt32() ?? 0;
        var accessToken = p?.TryGetProperty("accessToken", out var at) == true ? at.GetString() : null;
        var steamId = p?.TryGetProperty("steamID64", out var sid) == true ? sid.GetString() : null;

        // Use provided token or stored one
        accessToken ??= AccessToken;
        steamId ??= SteamID?.ConvertToUInt64().ToString();

        if (string.IsNullOrEmpty(accessToken) || string.IsNullOrEmpty(steamId))
        {
            // Try to get token via CM session
            if (IsLoggedOn && SteamID != null)
            {
                steamId = SteamID.ConvertToUInt64().ToString();
                if (string.IsNullOrEmpty(accessToken) && !string.IsNullOrEmpty(RefreshToken))
                {
                    try
                    {
                        var tokenResult = await _client.Authentication.GenerateAccessTokenForAppAsync(SteamID!, RefreshToken!, false);
                        accessToken = tokenResult.AccessToken;
                        AccessToken = accessToken;
                        IpcServer.Log("cloudEnumerate: generated fresh access token via CM");
                    }
                    catch (Exception ex)
                    {
                        IpcServer.Log($"cloudEnumerate: token generation failed: {ex.Message}");
                    }
                }
            }

            if (string.IsNullOrEmpty(accessToken) || string.IsNullOrEmpty(steamId))
                return new { success = false, error = "Need accessToken and steamID64" };
        }

        IpcServer.Log($"cloudEnumerate: fetching cloud files for appid={appId} via web...");

        try
        {
            var files = await EnumerateCloudFilesViaWeb(appId, steamId, accessToken);
            IpcServer.Log($"cloudEnumerate: found {files.Count} files for appid={appId}");
            return new { files, totalFound = files.Count };
        }
        catch (Exception ex)
        {
            IpcServer.Log($"cloudEnumerate: web scrape failed: {ex.Message}");
            return new { success = false, error = ex.Message };
        }
    }

    /// <summary>
    /// Enumerate cloud files via Steam's web interface (works with regular access tokens).
    /// </summary>
    private static async Task<List<object>> EnumerateCloudFilesViaWeb(uint appId, string steamId, string accessToken)
    {
        var cookie = $"{steamId}%7C%7C{accessToken}";
        var url = $"https://store.steampowered.com/account/remotestorageapp/?appid={appId}";

        using var handler = new HttpClientHandler();
        handler.CookieContainer = new CookieContainer();
        handler.CookieContainer.Add(new Uri("https://store.steampowered.com"),
            new Cookie("steamLoginSecure", cookie));

        using var http = new HttpClient(handler);
        http.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Jack/1.0");
        http.Timeout = TimeSpan.FromSeconds(30);

        var html = await http.GetStringAsync(url);
        IpcServer.Log($"cloudEnumerate web: got {html.Length} bytes of HTML");

        // Parse the HTML table rows
        // Each file has: <tr> with <td> cells for root, filename, size, date, download link
        var files = new List<object>();
        var rowPattern = new Regex(@"<tr[^>]*>\s*(?:<td[^>]*>\s*(.*?)\s*</td>\s*)+</tr>", RegexOptions.Singleline);
        var cellPattern = new Regex(@"<td[^>]*>\s*(.*?)\s*</td>", RegexOptions.Singleline);
        var linkPattern = new Regex(@"href=""([^""]+)""");

        var rows = rowPattern.Matches(html);
        foreach (Match row in rows)
        {
            var cells = cellPattern.Matches(row.Value);
            if (cells.Count < 3) continue;

            // Extract cell text, stripping HTML tags
            var cellTexts = new List<string>();
            string? downloadUrl = null;
            foreach (Match cell in cells)
            {
                var cellHtml = cell.Groups[1].Value;
                var linkMatch = linkPattern.Match(cellHtml);
                if (linkMatch.Success)
                    downloadUrl = linkMatch.Groups[1].Value;
                cellTexts.Add(Regex.Replace(cellHtml, @"<[^>]+>", "").Trim());
            }

            // Skip header row
            if (cellTexts.Any(t => t == "File Name" || t == "File Size")) continue;
            if (string.IsNullOrEmpty(downloadUrl)) continue;

            // Determine filename and root from cells
            string filename;
            string root = "";
            string size = "";
            string date = "";

            if (cellTexts.Count >= 5)
            {
                // Has root prefix column
                root = cellTexts[0];
                filename = cellTexts[1];
                size = cellTexts[2];
                date = cellTexts[3];
            }
            else if (cellTexts.Count >= 4)
            {
                // May or may not have root
                filename = cellTexts[0];
                size = cellTexts[1];
                date = cellTexts[2];
            }
            else
            {
                filename = cellTexts[0];
                size = cellTexts.Count > 1 ? cellTexts[1] : "";
            }

            if (string.IsNullOrEmpty(filename)) continue;

            IpcServer.Log($"  Cloud file: root={root} name={filename} size={size} url={downloadUrl}");
            files.Add(new
            {
                filename,
                root,
                size,
                date,
                url = downloadUrl,
            });
        }

        return files;
    }

    private async Task<object?> HandleCloudGetChangelist(JsonElement? p)
    {
        // Redirect to the web-based enumerate (changelist not needed with web approach)
        return await HandleCloudEnumerate(p);
    }

    /// <summary>
    /// Upload a single file to Steam Cloud via CM Client service methods.
    /// Uses Cloud.ClientBeginFileUpload#1 / Cloud.ClientCommitFileUpload#1 (CloudKit approach).
    /// Params: appID, filename, fileData (base64)
    /// </summary>
    private async Task<object?> HandleCloudUpload(JsonElement? p)
    {
        var appId = p?.GetProperty("appID").GetUInt32() ?? 0;
        var filename = p?.GetProperty("filename").GetString() ?? "";
        var fileDataB64 = p?.GetProperty("fileData").GetString() ?? "";

        var fileData = Convert.FromBase64String(fileDataB64);
        var fileSha = System.Security.Cryptography.SHA1.HashData(fileData);

        IpcServer.Log($"cloudUpload: file={filename} size={fileData.Length} appid={appId}");

        await EnsureLoggedIn(p);

        if (!IsLoggedOn || !_client.IsConnected)
            return new { success = false, error = "Not logged in to Steam CM" };

        try
        {
            // Step 1: ClientBeginFileUpload — ask Steam for upload URL
            IpcServer.Log("cloudUpload: sending Cloud.ClientBeginFileUpload#1...");
            var beginReq = new CCloud_ClientBeginFileUpload_Request
            {
                appid = appId,
                filename = filename,
                file_size = (uint)fileData.Length,
                raw_file_size = (uint)fileData.Length,
                file_sha = fileSha,
                time_stamp = (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                can_encrypt = true,
            };

            var beginJob = _unifiedMessages.SendMessage<CCloud_ClientBeginFileUpload_Request,
                CCloud_ClientBeginFileUpload_Response>("Cloud.ClientBeginFileUpload#1", beginReq);
            beginJob.Timeout = TimeSpan.FromSeconds(30);
            var beginResp = await beginJob;

            IpcServer.Log($"cloudUpload: ClientBeginFileUpload EResult={beginResp.Result}");

            if (beginResp.Result != EResult.OK)
                return new { success = false, error = $"ClientBeginFileUpload failed: {beginResp.Result}" };

            var body = beginResp.Body;

            // If no block requests, file already exists in cloud with same SHA
            if (body.block_requests.Count == 0)
            {
                IpcServer.Log("cloudUpload: file already exists in cloud (same SHA), committing...");
                await CommitCloudUpload(appId, filename, fileSha, false);
                return new { success = true, method = "cm", alreadyExists = true };
            }

            // Step 2: HTTP PUT to each block request URL
            using var httpClient = new HttpClient();
            foreach (var block in body.block_requests)
            {
                var scheme = block.use_https ? "https" : "http";
                var uploadUrl = $"{scheme}://{block.url_host}{block.url_path}";
                IpcServer.Log($"cloudUpload: uploading block to {uploadUrl}");

                using var content = new ByteArrayContent(fileData);
                foreach (var header in block.request_headers)
                {
                    switch (header.name)
                    {
                        case "Content-Type":
                        case "Content-Length":
                            content.Headers.TryAddWithoutValidation(header.name, header.value);
                            break;
                        case "Content-Disposition":
                            var val = header.value.TrimEnd(';');
                            content.Headers.TryAddWithoutValidation(header.name, val);
                            break;
                        default:
                            httpClient.DefaultRequestHeaders.TryAddWithoutValidation(header.name, header.value);
                            break;
                    }
                }

                var putResp = await httpClient.PutAsync(uploadUrl, content);
                IpcServer.Log($"cloudUpload: PUT status={putResp.StatusCode}");

                if (!putResp.IsSuccessStatusCode && putResp.StatusCode != System.Net.HttpStatusCode.Created)
                {
                    IpcServer.Log($"cloudUpload: upload failed with {putResp.StatusCode}");
                    await CommitCloudUpload(appId, filename, fileSha, false);
                    return new { success = false, error = $"HTTP PUT failed: {putResp.StatusCode}" };
                }
            }

            // Step 3: Commit the upload
            var committed = await CommitCloudUpload(appId, filename, fileSha, true);
            IpcServer.Log($"cloudUpload: commit result={committed}");

            return new { success = committed, method = "cm" };
        }
        catch (TaskCanceledException)
        {
            IpcServer.Log("cloudUpload: timed out waiting for Steam CM response");
            return new { success = false, error = "Steam CM timed out — Cloud.ClientBeginFileUpload not supported" };
        }
        catch (Exception ex)
        {
            IpcServer.Log($"cloudUpload: error: {ex.Message}");
            return new { success = false, error = ex.Message };
        }
    }

    private async Task<bool> CommitCloudUpload(uint appId, string filename, byte[] fileSha, bool succeeded)
    {
        var commitReq = new CCloud_ClientCommitFileUpload_Request
        {
            appid = appId,
            filename = filename,
            file_sha = fileSha,
            transfer_succeeded = succeeded,
        };

        var commitJob = _unifiedMessages.SendMessage<CCloud_ClientCommitFileUpload_Request,
            CCloud_ClientCommitFileUpload_Response>("Cloud.ClientCommitFileUpload#1", commitReq);
        commitJob.Timeout = TimeSpan.FromSeconds(30);
        var commitResp = await commitJob;

        IpcServer.Log($"cloudUpload: CommitFileUpload EResult={commitResp.Result} committed={commitResp.Body.file_committed}");
        return commitResp.Body.file_committed;
    }

    private async Task<object?> HandleGetAccessToken(JsonElement? _)
    {
        if (!IsLoggedOn || string.IsNullOrEmpty(RefreshToken))
            return new { success = false, error = "Not logged in" };

        // Use SteamKit2 to generate an access token via CM session
        try
        {
            var result = await _client.Authentication.GenerateAccessTokenForAppAsync(SteamID!, RefreshToken!, false);
            AccessToken = result.AccessToken;
            return new { success = true, accessToken = result.AccessToken };
        }
        catch (Exception ex)
        {
            IpcServer.Log($"Token refresh failed: {ex.Message}");
            // Fall back to stored token if available
            if (!string.IsNullOrEmpty(AccessToken))
                return new { success = true, accessToken = AccessToken };
            return new { success = false, error = ex.Message };
        }
    }

    private Task<object?> HandleDisconnect(JsonElement? _)
    {
        _steamUser.LogOff();
        _client.Disconnect();
        return Task.FromResult<object?>(new { success = true });
    }

    // ──────────────────────────────────────────────
    // Callbacks
    // ──────────────────────────────────────────────

    private void OnConnected(SteamClient.ConnectedCallback cb)
    {
        IpcServer.Log("Connected to Steam CM");
        _connectTcs?.TrySetResult(true);
    }

    private void OnDisconnected(SteamClient.DisconnectedCallback cb)
    {
        IpcServer.Log("Disconnected from Steam CM");
        IsLoggedOn = false;
        _connectTcs?.TrySetResult(false);
        _logOnTcs?.TrySetResult(false);
        _ipc.SendEvent("disconnected", new { userInitiated = cb.UserInitiated });
    }

    private TaskCompletionSource<bool>? _logOnTcs;

    private Task<bool> WaitForLogOn()
    {
        _logOnTcs = new TaskCompletionSource<bool>();
        return _logOnTcs.Task;
    }

    private void OnLoggedOn(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result == EResult.OK)
        {
            IsLoggedOn = true;
            SteamID = cb.ClientSteamID;
            IpcServer.Log($"Logged on as {AccountName} (SteamID={SteamID?.ConvertToUInt64()})");
            _logOnTcs?.TrySetResult(true);
        }
        else
        {
            IpcServer.Log($"Logon failed: {cb.Result} / {cb.ExtendedResult}");
            _logOnTcs?.TrySetResult(false);
        }
    }

    private void OnLoggedOff(SteamUser.LoggedOffCallback cb)
    {
        IpcServer.Log($"Logged off: {cb.Result}");
        IsLoggedOn = false;
    }

    private void OnLicenseList(SteamApps.LicenseListCallback cb)
    {
        if (cb.Result != EResult.OK) return;

        // We get package IDs, not app IDs directly.
        // Store package IDs; app ID resolution requires PICS.
        var packageIds = cb.LicenseList.Select(l => l.PackageID).ToList();
        IpcServer.Log($"License list received: {packageIds.Count} packages");

        // For now, we'll resolve app IDs via PICS when requested
        _ownedPackageIDs = packageIds;
    }

    private List<uint> _ownedPackageIDs = new();
}

/// <summary>
/// Custom authenticator that bridges SteamKit2's 2FA prompts to Swift via IPC events.
/// </summary>
public class BridgeAuthenticator : IAuthenticator
{
    private readonly IpcServer _ipc;
    private TaskCompletionSource<string>? _codeTcs;

    public BridgeAuthenticator(IpcServer ipc)
    {
        _ipc = ipc;

        // Register the guard code submission handler
        _ipc.RegisterHandler("submitGuardCode", async p =>
        {
            var code = p?.GetProperty("code").GetString() ?? "";
            _codeTcs?.TrySetResult(code);
            return new { success = true };
        });
    }

    public Task<string> GetDeviceCodeAsync(bool previousCodeWasIncorrect)
    {
        _codeTcs = new TaskCompletionSource<string>();
        _ipc.SendEvent("steamGuardRequired", new
        {
            type = "deviceCode",
            previousCodeWasIncorrect
        });
        return _codeTcs.Task;
    }

    public Task<string> GetEmailCodeAsync(string email, bool previousCodeWasIncorrect)
    {
        _codeTcs = new TaskCompletionSource<string>();
        _ipc.SendEvent("steamGuardRequired", new
        {
            type = "emailCode",
            email,
            previousCodeWasIncorrect
        });
        return _codeTcs.Task;
    }

    public Task<bool> AcceptDeviceConfirmationAsync()
    {
        _ipc.SendEvent("steamGuardRequired", new { type = "deviceConfirmation" });
        // SteamKit2 will poll for acceptance on the server side
        return Task.FromResult(true);
    }
}
