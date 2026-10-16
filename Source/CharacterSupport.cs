using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using HarmonyLib;
using Mortal.Core;
using Mortal.Story;
using UnityEngine;
using UnityEngine.AddressableAssets;
using UnityEngine.ResourceManagement.AsyncOperations;
using UnityEngine.ResourceManagement.ResourceLocations;
using UnityEngine.UI;

namespace ZhaoHuoNatural
{
    public sealed partial class Plugin
    {
        private HashSet<string> enabledRoles = new HashSet<string>(StringComparer.Ordinal);
        private bool configurationValid = true;
        private readonly HashSet<string> scopeWarnings = new HashSet<string>(StringComparer.Ordinal);
        private static readonly System.Reflection.FieldInfo OperationList = AccessTools.Field(typeof(StoryCharacterController), "_operationList");

        private void LoadCharacterConfiguration()
        {
            enabledRoles.Clear();
            try
            {
                string file = CharacterPolicy.ContainedPath(Root, "characters.json");
                if (!File.Exists(file)) { enabledRoles.Add("player"); Logger.LogInfo("Characters: legacy player-only configuration."); return; }
                if (new FileInfo(file).Length > 65536) throw new InvalidDataException("characters.json is too large.");
                enabledRoles = CharacterPolicy.EnabledRoles(CharacterConfigurationJson.Parse(File.ReadAllText(file, Encoding.UTF8)));
                Logger.LogInfo("Characters enabled: " + string.Join(",", enabledRoles.OrderBy(x => x, StringComparer.Ordinal).ToArray()));
            }
            catch (Exception error)
            {
                enabledRoles.Clear();
                configurationValid = false;
                Logger.LogError("Invalid characters.json; all portrait replacements disabled. " + error.Message);
            }
        }

        internal string RoleFor(StoryCharacterData data)
        {
            if (data == null) return null;
            try
            {
                string role = CharacterPolicy.RoleForIdentity(data.Id, data.name);
                return role != null && enabledRoles.Contains(role) ? role : null;
            }
            catch { return null; }
        }

        private string CanonicalAsset(string addressKey)
        {
            if (string.IsNullOrEmpty(addressKey)) return null;
            string resolved = null;
            foreach (var locator in Addressables.ResourceLocators)
            {
                IList<IResourceLocation> locations;
                if (!locator.Locate(addressKey, typeof(Sprite), out locations)) continue;
                foreach (IResourceLocation location in locations)
                {
                    string candidate = location.InternalId.Replace('\\', '/').ToLowerInvariant();
                    if (resolved != null && resolved != candidate) return null;
                    resolved = candidate;
                }
            }
            return resolved;
        }

        internal sealed class PortraitLoad
        {
            internal StoryCharacterData Data;
            internal string Role;
            internal string GameId;
            internal string CharacterName;
            internal List<AsyncOperationHandle<Sprite>> Handles;
            internal AsyncOperationHandle<Sprite>[] Previous;
            internal string[] Expressions;
        }

        // Snapshot at the beginning of the actual coroutine, not at its creation.
        // Exactly one new handle belongs to LoadPortrait/Sync. Bulk appends one per
        // input item, including failed handles. A changed prefix/count indicates
        // concurrent loading or an unsupported engine change: leave originals alone.
        internal PortraitLoad CaptureLoad(StoryCharacterController controller, string key, StoryCharaterImageItem[] bulk)
        {
            try
            {
                if (controller == null) return null;
                string role = RoleFor(controller.Data);
                if (role == null || OperationList == null) return null;
                StoryCharaterImageItem[] items;
                if (bulk != null) items = bulk.ToArray();
                else
                {
                    if (controller.Data.PortraitResourceList == null) return null;
                    items = controller.Data.PortraitResourceList.Where(x => x != null && x.Mapping != null && x.Mapping.Value == key).ToArray();
                    if (items.Length != 1) return null;
                }
                var handles = OperationList.GetValue(controller) as List<AsyncOperationHandle<Sprite>>;
                if (handles == null || items.Length == 0) return null;
                string[] expressions = items.Select(x => x == null ? null : CharacterPolicy.ExpressionForIdentityAsset(controller.Data.Id, controller.Data.name, CanonicalAsset(x.AddressKey))).ToArray();
                if (!expressions.Any(x => x != null)) return null;
                return new PortraitLoad { Data = controller.Data, Role = role, GameId = controller.Data.Id, CharacterName = controller.Data.name, Handles = handles, Previous = handles.ToArray(), Expressions = expressions };
            }
            catch (Exception error) { WarnScope("capture", error.Message); return null; }
        }

        internal void CompleteLoad(StoryCharacterController controller, PortraitLoad load)
        {
            if (load == null || controller == null) return;
            try
            {
                if (controller.Data != load.Data || RoleFor(controller.Data) != load.Role || controller.Data.Id != load.GameId || controller.Data.name != load.CharacterName || controller.Portraits == null ||
                    !ReferenceEquals(OperationList.GetValue(controller), load.Handles)) return;
                // A cached load adds no handle and already has its replacement.
                if (load.Handles.Count == load.Previous.Length) return;
                if (load.Handles.Count != load.Previous.Length + load.Expressions.Length) { WarnScope("overlap", "Ambiguous portrait load; original retained."); return; }
                for (int i = 0; i < load.Previous.Length; i++) if (!load.Handles[i].Equals(load.Previous[i])) return;
                for (int i = 0; i < load.Expressions.Length; i++)
                {
                    string expression = load.Expressions[i];
                    AsyncOperationHandle<Sprite> handle = load.Handles[load.Previous.Length + i];
                    if (expression == null || !handle.IsValid() || handle.Status != AsyncOperationStatus.Succeeded) continue;
                    Sprite original = handle.Result;
                    if (original == null || original.name != expression || !controller.Portraits.Contains(original)) continue;
                    Sprite replacement = GetRoleReplacement(load.Role, load.CharacterName, original);
                    if (replacement == original) continue;
                    for (int index = 0; index < controller.Portraits.Count; index++)
                        if (controller.Portraits[index] == original) controller.Portraits[index] = replacement;
                    if (controller.State != null && controller.State.allPortraits != null)
                        foreach (Image image in controller.State.allPortraits)
                            if (image != null && image.sprite == original) image.sprite = replacement;
                    if (controller.ProfileSprite == original) controller.ProfileSprite = replacement;
                }
            }
            catch (Exception error) { Logger.LogError("Portrait replacement failed; original remains available. " + error); }
        }

        private void WarnScope(string key, string message)
        {
            if (scopeWarnings.Add(key)) Logger.LogWarning("Portrait scope check: " + message);
        }

        internal static IEnumerator AfterScopedLoad(IEnumerator original, StoryCharacterController controller, string key, StoryCharaterImageItem[] bulk)
        {
            PortraitLoad load = Instance == null ? null : Instance.CaptureLoad(controller, key, bulk);
            try { while (original.MoveNext()) yield return original.Current; }
            finally { (original as IDisposable)?.Dispose(); }
            if (Instance != null) Instance.CompleteLoad(controller, load);
        }

        private readonly List<string> characterDiagnosticRows = new List<string>();
        private readonly List<string> characterDiagnosticSummary = new List<string>();

        private IEnumerator CharacterDiagnostics()
        {
            if (!configurationValid) throw new InvalidOperationException("Invalid character configuration cannot pass diagnostics.");
            characterDiagnosticRows.Add("character\tidentity\texpression\tload_path\tstatus\twidth\theight\tui_sprite_match");
            foreach (CharacterPolicy.RoleBinding binding in CharacterPolicy.Bindings.Where(x => x.Id != "player"))
            {
                string role = binding.Id;
                string gameId = binding.Identities[0].Id;
                string objectName = binding.Identities[0].Name;
                var locations = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var locator in Addressables.ResourceLocators)
                    foreach (object key in locator.Keys)
                    {
                        IList<IResourceLocation> found;
                        if (!locator.Locate(key, typeof(Sprite), out found)) continue;
                        foreach (IResourceLocation location in found)
                        {
                            string expression = CharacterPolicy.ExpressionForIdentityAsset(gameId, objectName, location.InternalId);
                            if (expression != null && !locations.ContainsKey(expression)) locations.Add(expression, key.ToString());
                        }
                    }
                if (locations.Count != binding.BaseResourceCount) throw new InvalidOperationException("Expected " + binding.BaseResourceCount + " verified base resources for " + role + "; found " + locations.Count);
                yield return VerifyCharacterFixture(role, gameId, objectName, locations, false, true);
                foreach (CharacterPolicy.IdentityBinding alias in binding.Identities.Skip(1))
                {
                    KeyValuePair<string, string> sample = locations.OrderBy(x => x.Key == "normal" ? "" : x.Key, StringComparer.Ordinal)
                        .FirstOrDefault(x => CharacterPolicy.ExpressionForIdentityAsset(alias.Id, alias.Name, CanonicalAsset(x.Value)) == x.Key);
                    if (sample.Key == null) throw new InvalidOperationException("Alias diagnostics require a verified shared resource: " + role + "/" + alias.Id);
                    yield return VerifyCharacterFixture(role, alias.Id, alias.Name, new Dictionary<string, string> { { sample.Key, sample.Value } }, false);
                }
                // Same named sprite, correct adult asset, but unapproved identity.
                // This must remain original even though the base asset is loaded.
                foreach (CharacterPolicy.IdentityBinding rejected in binding.RejectedIdentities)
                    yield return VerifyCharacterFixture(role, rejected.Id, rejected.Name, new Dictionary<string, string> { { "normal", locations["normal"] } }, true);
                yield return VerifyCharacterFixture(role, "__scope_probe", objectName, new Dictionary<string, string> { { "normal", locations["normal"] } }, true);
            }
            File.WriteAllLines(Path.Combine(diagnosticDir, "characters.tsv"), characterDiagnosticRows.ToArray(), Encoding.UTF8);
            File.WriteAllLines(Path.Combine(diagnosticDir, "characters-summary.txt"), characterDiagnosticSummary.ToArray(), Encoding.UTF8);
        }

        private IEnumerator VerifyCharacterFixture(string role, string gameId, string objectName, Dictionary<string, string> locations, bool mustRemainOriginal, bool testBulk = false)
        {
            Stage("character fixture " + role + "/" + gameId);
            GameObject go = null, canvasObject = null;
            StoryCharacterData data = null;
            OBB.Framework.Data.StoryMappingItem identity = null;
            var mappingObjects = new List<OBB.Framework.Data.StoryMappingItem>();
            try
            {
                canvasObject = new GameObject("Character portrait verification", typeof(RectTransform), typeof(Canvas), typeof(CanvasScaler));
                Canvas canvas = canvasObject.GetComponent<Canvas>(); canvas.renderMode = RenderMode.ScreenSpaceOverlay; canvas.sortingOrder = 32761;
                CanvasScaler scaler = canvasObject.GetComponent<CanvasScaler>(); scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize; scaler.referenceResolution = new Vector2(1920, 1080);
                Image background = RectObject("Background", canvasObject.transform, Vector2.zero, Vector2.one).gameObject.AddComponent<Image>(); background.color = new Color(.08f, .1f, .1f, 1); background.raycastTarget = false;
                Label(canvasObject.transform, role + " / " + gameId + " / isolated real load fixture", new Vector2(0, .95f), Vector2.one, 26);
                RectTransform holder = RectObject("GamePortraitHolder", canvasObject.transform, Vector2.zero, Vector2.one);
                go = new GameObject("Isolated character fixture");
                StoryCharacterController controller = go.AddComponent<StoryCharacterController>();
                data = ScriptableObject.CreateInstance<StoryCharacterData>(); data.name = objectName;
                identity = ScriptableObject.CreateInstance<OBB.Framework.Data.StoryMappingItem>(); identity.Value = gameId;
                SetField(data, typeof(StoryCharacterData), "_mapping", identity);
                var items = new List<StoryCharaterImageItem>();
                foreach (var location in locations.OrderBy(x => x.Key == "normal" ? "" : x.Key))
                {
                    var mapping = ScriptableObject.CreateInstance<OBB.Framework.Data.StoryMappingItem>(); mapping.Value = location.Key; mappingObjects.Add(mapping);
                    var item = new StoryCharaterImageItem(); SetField(item, typeof(StoryCharaterImageItem), "_mapping", mapping); SetField(item, typeof(StoryCharaterImageItem), "_addressKey", location.Value); items.Add(item);
                }
                SetField(data, typeof(StoryCharacterData), "_portraitResourceList", items.ToArray());
                controller.Data = data; SetField(controller, typeof(Fungus.Character), "portraits", new List<Sprite>()); controller.State.holder = holder;
                yield return controller.Setup(data);
                int replaced = 0, index = 0;
                var labels = new List<GameObject>();
                foreach (var entry in locations.OrderBy(x => x.Key == "normal" ? "" : x.Key))
                {
                    string expression = entry.Key;
                    bool sync = index % 2 != 0;
                    if (sync) controller.LoadPortraitSync(expression); else yield return controller.LoadPortrait(expression);
                    Sprite sprite = controller.GetPortrait(controller.GetPortraitName(expression));
                    Image image = controller.State.allPortraits.FirstOrDefault(x => x != null && x.sprite == sprite);
                    if (sprite == null || image == null) throw new InvalidOperationException("Character fixture did not expose its real UI sprite.");
                    bool changed = replacements.Contains(sprite.GetInstanceID());
                    bool expected = !mustRemainOriginal && ResolveRoleFile(role, objectName, expression) != null;
                    if (changed != expected) throw new InvalidOperationException("Character replacement scope mismatch: " + role + "/" + gameId + "/" + expression);
                    int[] layout;
                    if (changed && layouts.TryGetValue(role + "/" + expression, out layout) && (sprite.texture.width != layout[0] || sprite.texture.height != layout[1])) throw new InvalidOperationException("Character canvas layout mismatch.");
                    if (changed) replaced++;
                    characterDiagnosticRows.Add(role + "\t" + gameId + "\t" + expression + "\t" + (sync ? "sync" : "async") + "\t" + (changed ? "REPLACED" : "ORIGINAL_FALLBACK") + "\t" + sprite.texture.width + "\t" + sprite.texture.height + "\ttrue");
                    int slot = index % 8, column = slot % 4, row = slot / 4;
                    image.rectTransform.SetParent(canvasObject.transform, false);
                    image.rectTransform.anchorMin = new Vector2(.02f + column * .245f, .08f + (1 - row) * .43f);
                    image.rectTransform.anchorMax = new Vector2(.255f + column * .245f, .48f + (1 - row) * .43f);
                    image.rectTransform.offsetMin = Vector2.zero; image.rectTransform.offsetMax = Vector2.zero;
                    image.color = Color.white; image.gameObject.SetActive(true);
                    int oldChildren = canvasObject.transform.childCount;
                    Label(canvasObject.transform, expression, image.rectTransform.anchorMin - new Vector2(0, .035f), new Vector2(image.rectTransform.anchorMax.x, image.rectTransform.anchorMin.y), 19);
                    labels.Add(canvasObject.transform.GetChild(oldChildren).gameObject);
                    index++;
                    if (index % 8 == 0 || index == locations.Count)
                    {
                        yield return new WaitForEndOfFrame();
                        ScreenCapture.CaptureScreenshot(Path.Combine(diagnosticDir, "character-" + role + "-" + gameId + "-" + ((index + 7) / 8) + ".png"));
                        yield return new WaitForSecondsRealtime(.3f);
                        foreach (Image previous in controller.State.allPortraits) if (previous != null) previous.gameObject.SetActive(false);
                        foreach (GameObject label in labels) UnityEngine.Object.Destroy(label); labels.Clear();
                    }
                    Sprite before = controller.GetPortrait(controller.GetPortraitName(expression));
                    controller.LoadPortraitSync(expression); yield return controller.LoadPortrait(expression);
                    if (controller.GetPortrait(controller.GetPortraitName(expression)) != before) throw new InvalidOperationException("Character cache changed on repeat load.");
                }
                characterDiagnosticSummary.Add(role + "/" + gameId + " resources=" + locations.Count + " replaced=" + replaced + " fallback=" + (locations.Count - replaced) + " scope=" + (mustRemainOriginal ? "negative" : "approved") + " PASS");
                if (testBulk && !mustRemainOriginal)
                {
                    // Bulk loading creates no UI Images in the original method. Test
                    // its returned portrait list on a fresh controller separately.
                    GameObject bulkObject = new GameObject("Isolated bulk portrait fixture");
                    try
                    {
                        var bulkController = bulkObject.AddComponent<StoryCharacterController>(); bulkController.Data = data;
                        SetField(bulkController, typeof(Fungus.Character), "portraits", new List<Sprite>());
                        SetField(bulkController, typeof(StoryCharacterController), "_operationList", new List<AsyncOperationHandle<Sprite>>());
                        SetField(bulkController, typeof(StoryCharacterController), "_dicPortrait", new Dictionary<string, string>());
                        yield return bulkController.LoadPortraitAssetByAddressable(items.ToArray());
                        if (bulkController.Portraits.Count != locations.Count) throw new InvalidOperationException("Bulk portrait count mismatch.");
                        foreach (Sprite sprite in bulkController.Portraits)
                        {
                            bool expected = ResolveRoleFile(role, objectName, sprite.name) != null;
                            if (replacements.Contains(sprite.GetInstanceID()) != expected) throw new InvalidOperationException("Bulk portrait scope mismatch: " + role + "/" + sprite.name);
                        }
                        characterDiagnosticSummary.Add(role + "/" + gameId + " bulk=" + bulkController.Portraits.Count + " PASS");
                    }
                    finally { UnityEngine.Object.Destroy(bulkObject); }
                }
            }
            finally
            {
                if (go != null) UnityEngine.Object.Destroy(go);
                if (canvasObject != null) UnityEngine.Object.Destroy(canvasObject);
                if (data != null) UnityEngine.Object.Destroy(data);
                if (identity != null) UnityEngine.Object.Destroy(identity);
                foreach (var mapping in mappingObjects) UnityEngine.Object.Destroy(mapping);
            }
        }
    }
}
