using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using BepInEx;
using BepInEx.Unity.Mono;
using Fungus;
using HarmonyLib;
using Mortal.Core;
using Mortal.Story;
using OBB.Framework.Data;
using UnityEngine;
using UnityEngine.AddressableAssets;
using UnityEngine.ResourceManagement.AsyncOperations;
using UnityEngine.ResourceManagement.ResourceLocations;
using UnityEngine.UI;
using Object = UnityEngine.Object;

namespace ZhaoHuoNatural
{
    [BepInPlugin("local.zhaohuo.naturalportrait", "Zhao Huo Character Portraits", "2.0.0")]
    public sealed partial class Plugin : BaseUnityPlugin
    {
        internal static Plugin Instance;
        internal string Root;
        private readonly Dictionary<string, Texture2D> textures = new Dictionary<string, Texture2D>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, Sprite> sprites = new Dictionary<string, Sprite>(StringComparer.Ordinal);
        private readonly HashSet<int> replacements = new HashSet<int>();
        private readonly Dictionary<string, string> mappings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, int[]> layouts = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> logged = new HashSet<string>(StringComparer.Ordinal);
        private Harmony harmony;
        private string diagnosticDir;
        private string diagnosticStage = "not started";
        private readonly List<string> diagnosticRows = new List<string>();

        private void Awake()
        {
            Instance = this;
            Root = Path.GetDirectoryName(Info.Location);
            LoadCharacterConfiguration();
            LoadMappings();
            LoadLayouts();
            harmony = new Harmony("local.zhaohuo.naturalportrait");
            harmony.PatchAll(typeof(Plugin).Assembly);
            Logger.LogInfo("Ready. Game=" + Application.version + ", Unity=" + Application.unityVersion + "; coroutine + synchronous portrait hooks installed; PNG files=" + (Directory.Exists(Path.Combine(Root, "Portraits")) ? Directory.GetFiles(Path.Combine(Root, "Portraits"), "*.png", SearchOption.AllDirectories).Length : 0));
            if (Environment.GetCommandLineArgs().Any(x => x == "--zhaohuo-portrait-selftest"))
                StartCoroutine(SafeDiagnostics(Diagnostics()));
        }

        private void LoadMappings()
        {
            string file = CharacterPolicy.ContainedPath(Root, "portrait-map.txt");
            if (!File.Exists(file)) return;
            foreach (string raw in File.ReadAllLines(file, Encoding.UTF8))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                int split = line.IndexOf('=');
                if (split <= 0) continue;
                string key = line.Substring(0, split).Trim();
                string value = line.Substring(split + 1).Trim();
                if (value.Length > 0) mappings[key] = value;
            }
        }

        private void LoadLayouts()
        {
            foreach (string role in CharacterPolicy.RoleIds)
                try { LoadRoleLayouts(role); }
                catch (Exception error) { Logger.LogWarning("Character layout unavailable: " + role + "; originals retained. " + error.Message); }
        }

        private void LoadRoleLayouts(string role)
        {
            string file = CharacterPolicy.ContainedPath(Root, CharacterPolicy.LayoutPath(role));
            if (!File.Exists(file)) return;
            foreach (string raw in File.ReadAllLines(file, Encoding.UTF8))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] fields = line.Split('\t');
                if (fields.Length != 7 || fields[0] == "expression") continue;
                int[] values = new int[6];
                bool valid = true;
                for (int i = 0; i < values.Length; i++) if (!int.TryParse(fields[i + 1], out values[i])) valid = false;
                if (!valid || values[0] <= 0 || values[1] <= 0 || values[2] < 0 || values[3] < 0 || values[4] <= 0 || values[5] <= 0 || values[2] + values[4] > values[0] || values[3] + values[5] > values[1])
                    Logger.LogWarning("Ignored invalid layout: " + fields[0]);
                else layouts[(role == "player" ? "" : role + "/") + fields[0]] = values;
            }
        }

        private Texture2D LoadTexture(string file, int[] layout)
        {
            Texture2D source = new Texture2D(2, 2, TextureFormat.RGBA32, false);
            if (!ImageConversion.LoadImage(source, File.ReadAllBytes(file), layout == null))
            {
                Object.Destroy(source);
                throw new InvalidDataException("Could not decode PNG: " + file);
            }
            if (layout == null) return source;
            Color32[] pixels = source.GetPixels32();
            int minX = source.width, minY = source.height, maxX = -1, maxY = -1;
            for (int y = 0; y < source.height; y++)
                for (int x = 0; x < source.width; x++)
                    if (pixels[y * source.width + x].a > 16)
                    {
                        if (x < minX) minX = x; if (x > maxX) maxX = x;
                        if (y < minY) minY = y; if (y > maxY) maxY = y;
                    }
            if (maxX < minX || maxY < minY) { Object.Destroy(source); throw new InvalidDataException("PNG has no visible pixels: " + file); }
            // Two source pixels retain the antialiased fringe around the alpha>16 bounds.
            minX = Math.Max(0, minX - 2); minY = Math.Max(0, minY - 2);
            maxX = Math.Min(source.width - 1, maxX + 2); maxY = Math.Min(source.height - 1, maxY + 2);
            int sourceWidth = maxX - minX + 1, sourceHeight = maxY - minY + 1;
            float fit = Math.Min((float)layout[4] / sourceWidth, (float)layout[5] / sourceHeight);
            int width = Math.Max(1, Math.Min(layout[4], Mathf.RoundToInt(sourceWidth * fit)));
            int height = Math.Max(1, Math.Min(layout[5], Mathf.RoundToInt(sourceHeight * fit)));
            int destinationX = layout[2] + (layout[4] - width) / 2;
            int destinationY = layout[3] + (layout[5] - height) / 2;
            RenderTexture previous = RenderTexture.active;
            RenderTexture scaled = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);
            Texture2D canvas = null;
            try
            {
                Graphics.Blit(source, scaled, new Vector2((float)sourceWidth / source.width, (float)sourceHeight / source.height), new Vector2((float)minX / source.width, (float)minY / source.height));
                RenderTexture.active = scaled;
                canvas = new Texture2D(layout[0], layout[1], TextureFormat.RGBA32, false);
                canvas.SetPixels32(new Color32[layout[0] * layout[1]]);
                canvas.ReadPixels(new Rect(0, 0, width, height), destinationX, destinationY, false);
                canvas.Apply(false, true);
                return canvas;
            }
            catch { if (canvas != null) Object.Destroy(canvas); throw; }
            finally { RenderTexture.active = previous; RenderTexture.ReleaseTemporary(scaled); Object.Destroy(source); }
        }

        internal static bool IsProtagonist(StoryCharacterData data)
        {
            try { return data != null && CharacterPolicy.RoleForIdentity(data.Id, data.name) == "player"; }
            catch { return false; }
        }

        private static bool UseSharedPortraits(string character)
        {
            return character == "唐門_主角" || character == "唐門_主角_自戀" || character == "唐門_主角_少年" || character == "Player_主角" || character == "Player_自戀";
        }

        private string ResolveFile(string character, string expression)
        {
            return ResolveRoleFile("player", character, expression);
        }

        private string ResolveRoleFile(string role, string character, string expression)
        {
            if (!enabledRoles.Contains(role) || !CharacterPolicy.AllowsExpression(role, expression)) return null;
            string portraitRoot = CharacterPolicy.ContainedPath(Root, CharacterPolicy.PortraitDirectory(role));
            if (role != "player")
            {
                if (!layouts.ContainsKey(role + "/" + expression)) return null;
                string npcFile = CharacterPolicy.ContainedPath(portraitRoot, expression + ".png");
                return File.Exists(npcFile) ? npcFile : null;
            }
            if (character != "Avatar" && !UseSharedPortraits(character)) return null;
            string relative;
            if (!mappings.TryGetValue(character + "/" + expression, out relative))
            {
                string direct = CharacterPolicy.ContainedPath(portraitRoot, character + "/" + expression + ".png");
                if (File.Exists(direct)) return direct;
                if (!UseSharedPortraits(character)) return null;
                if (!mappings.TryGetValue(expression, out relative)) relative = expression + ".png";
            }
            string full = CharacterPolicy.ContainedPath(portraitRoot, relative);
            return File.Exists(full) ? full : null;
        }

        internal Sprite GetReplacement(string character, Sprite original)
        {
            return GetRoleReplacement("player", character, original);
        }

        private Sprite GetRoleReplacement(string role, string character, Sprite original)
        {
            if (original == null || replacements.Contains(original.GetInstanceID())) return original;
            string file = ResolveRoleFile(role, character, original.name);
            if (file == null) return original;
            int[] layout;
            if (role != "player") layouts.TryGetValue(role + "/" + original.name, out layout);
            else if (!layouts.TryGetValue(character + "/" + original.name, out layout)) layouts.TryGetValue(original.name, out layout);
            string textureKey = file + (layout == null ? "" : "\n" + string.Join(",", layout.Select(x => x.ToString()).ToArray()));
            string cacheKey = role + "\n" + character + "\n" + original.GetInstanceID() + "\n" + file;
            Sprite replacement;
            if (sprites.TryGetValue(cacheKey, out replacement) && replacement != null) return replacement;
            Texture2D texture;
            if (!textures.TryGetValue(textureKey, out texture) || texture == null)
            {
                texture = LoadTexture(file, layout);
                texture.name = "ZhaoHuoNatural_" + Path.GetFileNameWithoutExtension(file);
                texture.wrapMode = TextureWrapMode.Clamp;
                texture.filterMode = FilterMode.Bilinear;
                texture.hideFlags = HideFlags.HideAndDontSave;
                textures[textureKey] = texture;
            }
            Rect oldRect = original.rect;
            Vector2 pivot = new Vector2(original.pivot.x / oldRect.width, original.pivot.y / oldRect.height);
            float scale = texture.height / oldRect.height;
            replacement = Sprite.Create(texture, new Rect(0, 0, texture.width, texture.height), pivot, original.pixelsPerUnit * scale, 0, SpriteMeshType.FullRect, original.border * scale);
            replacement.name = original.name;
            replacement.hideFlags = HideFlags.HideAndDontSave;
            sprites[cacheKey] = replacement;
            replacements.Add(replacement.GetInstanceID());
            string logKey = role + "/" + character + "/" + original.name;
            if (logged.Add(logKey)) Logger.LogInfo("REPLACED " + logKey + " -> " + Path.GetFileName(file) + " [" + texture.width + "x" + texture.height + "]");
            return replacement;
        }

        internal void ApplyAvatar(PlayerAvatarPanel panel)
        {
            try
            {
                Image image = (Image)AccessTools.Field(typeof(PlayerAvatarPanel), "_avatarImage").GetValue(panel);
                if (image == null || image.sprite == null) return;
                // Avatar replacement is deliberately opt-in, via Portraits/Avatar/<original sprite name>.png
                // or a portrait-map.txt entry Avatar/<original sprite name>=relative PNG path.
                image.sprite = GetReplacement("Avatar", image.sprite);
            }
            catch (Exception error) { Logger.LogError("Avatar replacement failed; keeping original. " + error); }
        }

        internal void ApplyPortraitImages(object panel, string[] fieldNames)
        {
            try
            {
                foreach (string fieldName in fieldNames)
                {
                    Image image = (Image)AccessTools.Field(panel.GetType(), fieldName).GetValue(panel);
                    if (image != null && image.sprite != null) image.sprite = GetReplacement("唐門_主角", image.sprite);
                }
            }
            catch (Exception error) { Logger.LogError("Protagonist panel replacement failed; keeping original. " + error); }
        }

        internal static IEnumerator DuringIntroduction(IEnumerator original, CharacterIntroPanel panel)
        {
            bool applied = false;
            try
            {
                while (original.MoveNext())
                {
                    if (!applied && Instance != null)
                    {
                        Instance.ApplyPortraitImages(panel, new[] { "_avatarImage", "_avatarImageBack1", "_avatarImageBack2" });
                        applied = true;
                    }
                    yield return original.Current;
                }
            }
            finally { (original as IDisposable)?.Dispose(); }
        }

        private IEnumerator SafeDiagnostics(IEnumerator routine)
        {
            Stack<IEnumerator> stack = new Stack<IEnumerator>();
            stack.Push(routine);
            while (stack.Count > 0)
            {
                object current = null;
                bool moved = false;
                Exception error = null;
                try { moved = stack.Peek().MoveNext(); if (moved) current = stack.Peek().Current; }
                catch (Exception ex) { error = ex; }
                if (error != null)
                {
                    Logger.LogError("SELFTEST FAILED: " + error);
                    if (diagnosticDir != null)
                    {
                        File.WriteAllText(Path.Combine(diagnosticDir, "FAILED.txt"), "Stage=" + diagnosticStage + "\n" + error, Encoding.UTF8);
                        File.WriteAllLines(Path.Combine(diagnosticDir, "portraits-partial.tsv"), diagnosticRows.ToArray(), Encoding.UTF8);
                    }
                    if (Environment.GetCommandLineArgs().Any(x => x == "--zhaohuo-selftest-exit")) Application.Quit();
                    yield break;
                }
                if (!moved) { (stack.Pop() as IDisposable)?.Dispose(); continue; }
                IEnumerator nested = current as IEnumerator;
                if (nested != null) { stack.Push(nested); continue; }
                yield return current;
            }
        }

        private void Stage(string message)
        {
            diagnosticStage = message;
            Logger.LogInfo("SELFTEST " + message);
            if (diagnosticDir != null) File.AppendAllText(Path.Combine(diagnosticDir, "progress.log"), DateTime.Now.ToString("O") + " " + message + "\n", Encoding.UTF8);
        }

        private void OnApplicationQuit()
        {
            if (diagnosticDir != null && !File.Exists(Path.Combine(diagnosticDir, "PASS.txt")) && !File.Exists(Path.Combine(diagnosticDir, "FAILED.txt")))
                File.WriteAllText(Path.Combine(diagnosticDir, "INTERRUPTED.txt"), "Application quit before test completion. Last stage=" + diagnosticStage, Encoding.UTF8);
        }

        private static void SetField(object target, Type type, string name, object value)
        {
            AccessTools.Field(type, name).SetValue(target, value);
        }

        private static RectTransform RectObject(string name, Transform parent, Vector2 min, Vector2 max)
        {
            GameObject go = new GameObject(name, typeof(RectTransform));
            RectTransform rect = go.GetComponent<RectTransform>();
            rect.SetParent(parent, false); rect.anchorMin = min; rect.anchorMax = max; rect.offsetMin = Vector2.zero; rect.offsetMax = Vector2.zero;
            return rect;
        }

        private static void Label(Transform parent, string text, Vector2 min, Vector2 max, int size)
        {
            RectTransform rect = RectObject("Label", parent, min, max);
            Text label = rect.gameObject.AddComponent<Text>();
            label.font = Resources.GetBuiltinResource<Font>("Arial.ttf"); label.text = text; label.fontSize = size;
            label.alignment = TextAnchor.MiddleCenter; label.color = new Color(0.87f, 0.83f, 0.72f); label.raycastTarget = false;
        }

        private IEnumerator Diagnostics()
        {
            diagnosticDir = Path.Combine(Root, "Diagnostics", DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(diagnosticDir);
            File.WriteAllText(Path.Combine(diagnosticDir, "RUNNING.txt"), "Game=" + Application.version + "\nUnity=" + Application.unityVersion + "\nThis test uses isolated StoryCharacterController fixtures with real Addressables resources and game-created Unity UI Images. It does not load or save gameplay.\n", Encoding.UTF8);
            Stage("waiting for game startup (5 seconds)");
            yield return new WaitForSecondsRealtime(5f);
            Stage("initializing Addressables");
            yield return Addressables.InitializeAsync();
            List<KeyValuePair<string, string>> locations = new List<KeyValuePair<string, string>>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            string narcissistNormalKey = null;
            foreach (var locator in Addressables.ResourceLocators)
            {
                foreach (object key in locator.Keys)
                {
                    IList<IResourceLocation> found;
                    if (!locator.Locate(key, typeof(Sprite), out found)) continue;
                    foreach (IResourceLocation item in found)
                    {
                        string path = item.InternalId.Replace('\\', '/');
                        if (narcissistNormalKey == null && path.EndsWith("/Player_自戀/normal.png", StringComparison.Ordinal)) narcissistNormalKey = key.ToString();
                        if (path.IndexOf("/Player_主角/", StringComparison.Ordinal) >= 0 && path.EndsWith(".png", StringComparison.OrdinalIgnoreCase) && seen.Add(path))
                            locations.Add(new KeyValuePair<string, string>(key.ToString(), Path.GetFileNameWithoutExtension(path)));
                    }
                }
            }
            locations = locations.OrderBy(x => x.Value == "normal" ? "" : x.Value).ToList();
            if (locations.Count == 0) throw new InvalidOperationException("No current protagonist Sprite resources found in Addressables locators.");
            Stage("located " + locations.Count + " current protagonist resources");

            GameObject canvasObject = new GameObject("ZhaoHuoNatural SELFTEST - no gameplay", typeof(RectTransform), typeof(Canvas), typeof(CanvasScaler));
            Object.DontDestroyOnLoad(canvasObject);
            Canvas canvas = canvasObject.GetComponent<Canvas>(); canvas.renderMode = RenderMode.ScreenSpaceOverlay; canvas.sortingOrder = 32760;
            CanvasScaler scaler = canvasObject.GetComponent<CanvasScaler>(); scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize; scaler.referenceResolution = new Vector2(1920, 1080);
            RectTransform backgroundRect = RectObject("Background", canvasObject.transform, Vector2.zero, Vector2.one);
            Image background = backgroundRect.gameObject.AddComponent<Image>(); background.color = new Color(0.08f, 0.10f, 0.10f, 1); background.raycastTarget = false;
            Label(canvasObject.transform, "ZHAO HUO / LIVE UNITY PORTRAIT VERIFICATION", new Vector2(0, .94f), Vector2.one, 27);
            Label(canvasObject.transform, "Actual game LoadPortrait + LoadPortraitSync / isolated diagnostic fixture / no savegame changes", Vector2.zero, new Vector2(1, .04f), 18);
            RectTransform holder = RectObject("GamePortraitHolder", canvasObject.transform, new Vector2(.03f, .08f), new Vector2(.47f, .93f));
            GameObject characterObject = new GameObject("ZhaoHuoNaturalDiagnosticCharacter");
            Object.DontDestroyOnLoad(characterObject);
            StoryCharacterController controller = characterObject.AddComponent<StoryCharacterController>();
            StoryCharacterData data = ScriptableObject.CreateInstance<StoryCharacterData>(); data.name = "唐門_主角";
            StoryMappingItem characterMapping = ScriptableObject.CreateInstance<StoryMappingItem>(); characterMapping.Value = "player"; characterMapping.Key = "SELFTEST";
            SetField(data, typeof(StoryCharacterData), "_mapping", characterMapping);
            var resourceItems = new List<StoryCharaterImageItem>();
            var mappingObjects = new List<StoryMappingItem>();
            foreach (var item in locations)
            {
                StoryMappingItem mapping = ScriptableObject.CreateInstance<StoryMappingItem>(); mapping.Key = item.Value; mapping.Value = item.Value; mappingObjects.Add(mapping);
                StoryCharaterImageItem resource = new StoryCharaterImageItem();
                SetField(resource, typeof(StoryCharaterImageItem), "_mapping", mapping);
                SetField(resource, typeof(StoryCharaterImageItem), "_addressKey", item.Key);
                resourceItems.Add(resource);
            }
            SetField(data, typeof(StoryCharacterData), "_portraitResourceList", resourceItems.ToArray());
            controller.Data = data;
            SetField(controller, typeof(Character), "portraits", new List<Sprite>());
            controller.State.holder = holder;
            float localizationDeadline = Time.realtimeSinceStartup + 45f;
            while (LocalizationManager.Instance == null && Time.realtimeSinceStartup < localizationDeadline) yield return null;
            if (LocalizationManager.Instance == null) throw new InvalidOperationException("Game localization did not initialize; cannot exercise normal StoryCharacterController.Setup path.");
            yield return controller.Setup(data);
            Stage("normal game Setup completed");
            diagnosticRows.Add("expression\tload_path\tstatus\twidth\theight\tui_sprite_match\tfile");
            int replacedCount = 0;
            int fallbackCount = 0;
            List<Image> pageImages = new List<Image>();
            List<GameObject> pageLabels = new List<GameObject>();
            for (int i = 0; i < locations.Count; i++)
            {
                string expression = locations[i].Value;
                bool sync = i % 2 != 0;
                if (sync) controller.LoadPortraitSync(expression); else yield return controller.LoadPortrait(expression);
                string spriteName = controller.GetPortraitName(expression);
                Sprite sprite = controller.GetPortrait(spriteName);
                if (sprite == null) throw new InvalidOperationException("Game returned no sprite for " + expression);
                Image uiImage = controller.State.allPortraits.FirstOrDefault(x => x != null && x.sprite == sprite);
                if (uiImage == null) throw new InvalidOperationException("Game UI image did not receive sprite for " + expression);
                bool replaced = replacements.Contains(sprite.GetInstanceID());
                if (replaced) replacedCount++; else fallbackCount++;
                string expectedFile = ResolveFile(data.name, sprite.name);
                if (expectedFile != null && !replaced) throw new InvalidOperationException("Available PNG was not applied: " + expression);
                int[] expectedLayout;
                if (replaced && layouts.TryGetValue(sprite.name, out expectedLayout) && (sprite.texture.width != expectedLayout[0] || sprite.texture.height != expectedLayout[1]))
                    throw new InvalidOperationException("Replacement canvas dimensions do not match layout: " + expression);
                diagnosticRows.Add(expression + "\t" + (sync ? "LoadPortraitSync" : "LoadPortrait") + "\t" + (replaced ? "REPLACED" : "ORIGINAL_FALLBACK") + "\t" + sprite.texture.width + "\t" + sprite.texture.height + "\ttrue\t" + (expectedFile ?? ""));
                uiImage.color = Color.white; uiImage.gameObject.SetActive(true);
                int slot = i % 8;
                RectTransform rect = uiImage.rectTransform;
                rect.SetParent(canvasObject.transform, false);
                int column = slot % 4; int row = slot / 4;
                rect.anchorMin = new Vector2(.02f + column * .245f, .09f + (1-row) * .42f);
                rect.anchorMax = new Vector2(.255f + column * .245f, .47f + (1-row) * .42f);
                rect.offsetMin = Vector2.zero; rect.offsetMax = Vector2.zero;
                pageImages.Add(uiImage);
                int priorChildren = canvasObject.transform.childCount;
                Label(canvasObject.transform, expression + (replaced ? " / PNG" : " / ORIGINAL"), new Vector2(rect.anchorMin.x, rect.anchorMin.y - .035f), new Vector2(rect.anchorMax.x, rect.anchorMin.y), 19);
                pageLabels.Add(canvasObject.transform.GetChild(priorChildren).gameObject);
                if (slot == 7 || i == locations.Count - 1)
                {
                    yield return new WaitForEndOfFrame();
                    string screenshot = Path.Combine(diagnosticDir, "portraits-" + (i / 8 + 1).ToString("00") + ".png");
                    ScreenCapture.CaptureScreenshot(screenshot);
                    yield return new WaitForSecondsRealtime(.3f);
                    Stage("rendered page " + (i / 8 + 1));
                    foreach (Image prior in pageImages) prior.gameObject.SetActive(false);
                    foreach (GameObject prior in pageLabels) Object.Destroy(prior);
                    pageImages.Clear(); pageLabels.Clear();
                }
            }
            // Reload an existing key through both methods: dictionary cache must preserve the replacement.
            string firstKey = locations[0].Value;
            Sprite before = controller.GetPortrait(controller.GetPortraitName(firstKey));
            controller.LoadPortraitSync(firstKey); yield return controller.LoadPortrait(firstKey);
            if (controller.GetPortrait(controller.GetPortraitName(firstKey)) != before) throw new InvalidOperationException("Repeated load changed cached sprite unexpectedly.");

            // Feed an original protagonist sprite through a non-protagonist controller and ensure it is untouched.
            // This tests character scoping even when NPC and protagonist sprite names collide (e.g. normal).
            List<AsyncOperationHandle<Sprite>> handles = (List<AsyncOperationHandle<Sprite>>)AccessTools.Field(typeof(StoryCharacterController), "_operationList").GetValue(controller);
            Sprite untouched = handles[0].Result;
            StoryCharacterData npcData = ScriptableObject.CreateInstance<StoryCharacterData>(); npcData.name = "__NPC_scope_probe";
            StoryMappingItem npcMapping = ScriptableObject.CreateInstance<StoryMappingItem>(); npcMapping.Value = "__NPC_scope_probe";
            SetField(npcData, typeof(StoryCharacterData), "_mapping", npcMapping);
            List<Sprite> heroPortraits = controller.Portraits;
            SetField(controller, typeof(Character), "portraits", new List<Sprite> { untouched });
            controller.Data = npcData;
            CompleteLoad(controller, CaptureLoad(controller, firstKey, null));
            if (controller.Portraits[0] != untouched || replacements.Contains(untouched.GetInstanceID())) throw new InvalidOperationException("Non-protagonist scope check failed.");
            controller.Data = data; SetField(controller, typeof(Character), "portraits", heroPortraits);
            Object.Destroy(npcData); Object.Destroy(npcMapping);

            Stage("testing real PlayerAvatarPanel.OnEnable, both talent branches");
            Sprite avatarNormal = untouched, avatarAlternative = untouched;
            bool foundLiveAvatar = false;
            foreach (PlayerAvatarPanel livePanel in Resources.FindObjectsOfTypeAll<PlayerAvatarPanel>())
            {
                Sprite first = (Sprite)AccessTools.Field(typeof(PlayerAvatarPanel), "_normal").GetValue(livePanel);
                Sprite second = (Sprite)AccessTools.Field(typeof(PlayerAvatarPanel), "_normal2").GetValue(livePanel);
                if (first != null && second != null) { avatarNormal = first; avatarAlternative = second; foundLiveAvatar = true; break; }
            }
            AsyncOperationHandle<Sprite> alternateHandle = default(AsyncOperationHandle<Sprite>);
            if (!foundLiveAvatar && narcissistNormalKey != null)
            {
                alternateHandle = Addressables.LoadAssetAsync<Sprite>(narcissistNormalKey);
                yield return alternateHandle;
                if (alternateHandle.Status == AsyncOperationStatus.Succeeded) avatarAlternative = alternateHandle.Result;
            }
            PlayerTalentData fixtureTalent = ScriptableObject.CreateInstance<PlayerTalentData>();
            RectTransform avatarRect = RectObject("Real PlayerAvatarPanel fixture", canvasObject.transform, new Vector2(.27f, .09f), new Vector2(.73f, .93f));
            avatarRect.gameObject.SetActive(false);
            Image avatarImage = avatarRect.gameObject.AddComponent<Image>(); avatarImage.preserveAspect = true; avatarImage.raycastTarget = false;
            PlayerAvatarPanel avatarPanel = avatarRect.gameObject.AddComponent<PlayerAvatarPanel>();
            SetField(avatarPanel, typeof(PlayerAvatarPanel), "_talentData", fixtureTalent);
            SetField(avatarPanel, typeof(PlayerAvatarPanel), "_avatarImage", avatarImage);
            SetField(avatarPanel, typeof(PlayerAvatarPanel), "_normal", avatarNormal);
            SetField(avatarPanel, typeof(PlayerAvatarPanel), "_normal2", avatarAlternative);
            int avatarReplaced = 0;
            for (int branch = 0; branch < 2; branch++)
            {
                fixtureTalent.Setup(branch);
                avatarRect.gameObject.SetActive(true);
                Sprite expectedOriginal = branch == 0 ? avatarNormal : avatarAlternative;
                bool changed = replacements.Contains(avatarImage.sprite.GetInstanceID());
                if (ResolveFile("Avatar", expectedOriginal.name) != null && !changed) throw new InvalidOperationException("PlayerAvatarPanel branch " + branch + " did not use available PNG.");
                if (changed) avatarReplaced++;
                diagnosticRows.Add("Avatar/" + expectedOriginal.name + "#" + branch + "\tPlayerAvatarPanel.OnEnable\t" + (changed ? "REPLACED" : "ORIGINAL_FALLBACK") + "\t" + avatarImage.sprite.texture.width + "\t" + avatarImage.sprite.texture.height + "\ttrue\t" + (ResolveFile("Avatar", expectedOriginal.name) ?? ""));
                yield return new WaitForEndOfFrame();
                ScreenCapture.CaptureScreenshot(Path.Combine(diagnosticDir, "avatar-panel-" + branch + ".png"));
                yield return new WaitForSecondsRealtime(.3f);
                avatarRect.gameObject.SetActive(false);
            }
            Object.Destroy(avatarRect.gameObject); Object.Destroy(fixtureTalent);
            if (alternateHandle.IsValid()) Addressables.Release(alternateHandle);

            yield return CharacterDiagnostics();

            File.WriteAllLines(Path.Combine(diagnosticDir, "portraits.tsv"), diagnosticRows.ToArray(), Encoding.UTF8);
            string summary = "PASS\nGame=" + Application.version + "\nUnity=" + Application.unityVersion + "\nResources=" + locations.Count + "\nReplaced=" + replacedCount + "\nOriginalFallback=" + fallbackCount + "\nNormalSetupPath=true\nAsyncAndSync=true\nUiSpriteMatch=true\nRepeatLoadCache=true\nNonProtagonistUnchanged=true\nAvatarPanelBranches=2\nAvatarPanelReplaced=" + avatarReplaced + "\nScope=isolated real StoryCharacterController and PlayerAvatarPanel fixtures, actual Addressables, game-created UI Images; no story/save simulation\n";
            File.WriteAllText(Path.Combine(diagnosticDir, "PASS.txt"), summary, Encoding.UTF8);
            Logger.LogInfo("SELFTEST PASS: resources=" + locations.Count + ", replaced=" + replacedCount + ", fallback=" + fallbackCount + "; reports=" + diagnosticDir);
            Object.Destroy(characterObject); Object.Destroy(canvasObject); Object.Destroy(data); Object.Destroy(characterMapping);
            foreach (StoryMappingItem item in mappingObjects) Object.Destroy(item);
            if (Environment.GetCommandLineArgs().Any(x => x == "--zhaohuo-selftest-exit")) { yield return new WaitForSecondsRealtime(1f); Application.Quit(); }
        }
    }

    [HarmonyPatch(typeof(StoryCharacterController), "LoadPortrait", new Type[] { typeof(string) })]
    internal static class AsyncPortraitPatch
    {
        private static void Postfix(StoryCharacterController __instance, string key, ref IEnumerator __result)
        {
            if (__result != null && Plugin.Instance != null && Plugin.Instance.RoleFor(__instance.Data) != null)
                __result = Plugin.AfterScopedLoad(__result, __instance, key, null);
        }
    }

    [HarmonyPatch(typeof(StoryCharacterController), "LoadPortraitSync", new Type[] { typeof(string) })]
    internal static class SyncPortraitPatch
    {
        private static void Prefix(StoryCharacterController __instance, string key, out Plugin.PortraitLoad __state)
        {
            __state = Plugin.Instance == null ? null : Plugin.Instance.CaptureLoad(__instance, key, null);
        }
        private static void Postfix(StoryCharacterController __instance, Plugin.PortraitLoad __state) { Plugin.Instance?.CompleteLoad(__instance, __state); }
    }

    [HarmonyPatch(typeof(StoryCharacterController), "LoadPortraitAssetByAddressable", new Type[] { typeof(StoryCharaterImageItem[]) })]
    internal static class BulkPortraitPatch
    {
        private static void Postfix(StoryCharacterController __instance, StoryCharaterImageItem[] list, ref IEnumerator __result)
        {
            if (__result != null && list != null && Plugin.Instance != null && Plugin.Instance.RoleFor(__instance.Data) != null)
                __result = Plugin.AfterScopedLoad(__result, __instance, null, list);
        }
    }

    [HarmonyPatch(typeof(PlayerAvatarPanel), "OnEnable")]
    internal static class AvatarPatch
    {
        private static void Postfix(PlayerAvatarPanel __instance) { Plugin.Instance?.ApplyAvatar(__instance); }
    }

    [HarmonyPatch(typeof(SocialStatPanel), "UpdateInfo")]
    internal static class SocialPortraitPatch
    {
        private static void Postfix(SocialStatPanel __instance)
        {
            RelationshipStat data = (RelationshipStat)AccessTools.Field(typeof(SocialStatPanel), "_currentData").GetValue(__instance);
            if (data != null && data.Type == RelationshipStatType.主角)
                Plugin.Instance?.ApplyPortraitImages(__instance, new[] { "_avatarImage" });
        }
    }

    [HarmonyPatch(typeof(CharacterIntroPanel), "TransitionAvatar", new Type[] { typeof(RelationshipStatType) })]
    internal static class IntroductionPortraitPatch
    {
        private static void Postfix(CharacterIntroPanel __instance, RelationshipStatType type, ref IEnumerator __result)
        {
            if (__result != null && type == RelationshipStatType.主角) __result = Plugin.DuringIntroduction(__result, __instance);
        }
    }
}
