using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace ZhaoHuoNatural
{
    [Serializable]
    public sealed class CharacterConfiguration
    {
        public int SchemaVersion;
        public CharacterSelection[] Characters;
    }

    [Serializable]
    public sealed class CharacterSelection
    {
        public string Id;
        public bool Enabled;
    }

    // This list describes verified game assets, not user-configurable matching rules.
    // Story IDs and Unity object names must BOTH match. Resource identity is checked
    // separately at the load boundary; a sprite's short name is never its identity.
    internal static class CharacterPolicy
    {
        internal static readonly string[] LegacyRoleIds = { "player", "tang-buyi", "xiahou-lan" };
        internal static readonly string[] RoleIds = { "player", "tang-buyi", "xiahou-lan", "tang-moling", "long-xiang", "yu-xiaomei", "tang-zheng" };
        internal const string AssetRoot = "assets/__project/images/characters/";
        internal sealed class IdentityBinding
        {
            internal readonly string Id, Name;
            private readonly HashSet<string> allowedAssets;
            internal IdentityBinding(string id, string name, string[] subset = null)
            {
                Id = id; Name = name;
                if (subset != null) allowedAssets = new HashSet<string>(subset.Select(NormalizeAsset), StringComparer.Ordinal);
            }
            internal bool Allows(string canonicalPath) { return allowedAssets == null || allowedAssets.Contains(NormalizeAsset(canonicalPath)); }
        }

        internal sealed class RoleBinding
        {
            internal readonly string Id;
            internal readonly IdentityBinding[] Identities, RejectedIdentities;
            private readonly Dictionary<string, string> assets = new Dictionary<string, string>(StringComparer.Ordinal);
            private readonly HashSet<string> expressions = new HashSet<string>(StringComparer.Ordinal);
            private readonly HashSet<string> originalOnly;
            internal RoleBinding(string id, string folder, string names, IdentityBinding[] identities, IdentityBinding[] rejected, string[] extraAssets = null, string originals = "")
            {
                Id = id; Identities = identities; RejectedIdentities = rejected;
                originalOnly = new HashSet<string>(originals.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries), StringComparer.Ordinal);
                foreach (string name in names.Split(' ')) AddAsset(AssetRoot + folder + "/" + name + ".png", name);
                if (extraAssets != null)
                    foreach (string path in extraAssets) AddAsset(AssetRoot + path, Path.GetFileNameWithoutExtension(path));
            }
            private void AddAsset(string path, string expression) { assets.Add(NormalizeAsset(path), expression); expressions.Add(expression); }
            internal string Expression(string path) { string expression; return path != null && assets.TryGetValue(NormalizeAsset(path), out expression) ? expression : null; }
            internal bool HasExpression(string expression) { return expression != null && expressions.Contains(expression) && !originalOnly.Contains(expression); }
            internal int BaseResourceCount { get { return assets.Where(x => Identities[0].Allows(x.Key)).Select(x => x.Value).Distinct(StringComparer.Ordinal).Count(); } }
        }

        private static string NormalizeAsset(string path) { return path == null ? null : path.Replace('\\', '/').ToLowerInvariant(); }
        private static string[] AssetSubset(string folder, string names) { return names.Split(' ').Select(x => AssetRoot + folder + "/" + x + ".png").ToArray(); }

        // All definitions are compiled from inspected StoryCharacterData records.
        // Neither characters.json nor image names can add identities or resources.
        internal static readonly RoleBinding[] Bindings = {
            new RoleBinding("player", "player_主角", "angry1 angry2 angry3 blood blood_laugh1 blood_nervous1 blood_no_weapon blood_no_weapon_laugh1 caught close_eye close_eye_laugh close_eye_nervous close_eye_nervous2 close_eye_powder determined die doubt eye_mask_nervous1 eye_mask_nervous2 fist_north_star gloomy2 god_thunder head hero_landing hurt hurt2 hurt_fist laugh1 laugh2 mask mud nervous1 nervous2 nervous3 normal oraora revel sad1 shake shake2 shock soul special1 stupid suck1 suck3 suck4",
                new[] { new IdentityBinding("player", "唐門_主角"), new IdentityBinding("player", "唐門_主角_自戀"), new IdentityBinding("player_young", "唐門_主角_少年", AssetSubset("player_主角", "normal")) },
                new[] { new IdentityBinding("player_child", "唐門_主角_幼年") },
                new[] { "player_自戀/normal.png", "player_自戀/angry1.png", "player_自戀/laugh1.png", "player_自戀/nervous1.png", "player_自戀/nervous3.png" }),
            new RoleBinding("tang-buyi", "brother1", "angry1 angry2 angry3 hand hat hurt laugh1 laugh2 nervous1 nervous2 nervous3 normal serious shock special1 suck",
                new[] { new IdentityBinding("brother1", "唐門_大師兄"), new IdentityBinding("brother1_2", "唐門_大師兄2"), new IdentityBinding("brother1_0", "唐門_大師兄_隱") },
                new[] { new IdentityBinding("brother1_young", "唐門_大師兄_少年") }, null, "hand"),
            new RoleBinding("xiahou-lan", "girl6_小蘭", "angry angry2 block blood cry droopy gloomy gloomy2 laugh1 love nervous nervous2 normal shy2 squint white",
                new[] { new IdentityBinding("girl6", "崆峒_小蘭"), new IdentityBinding("girl6_1", "崆峒_小蘭_早", AssetSubset("girl6_小蘭", "angry angry2 block blood cry gloomy gloomy2 laugh1 love nervous nervous2 normal shy2")) },
                new[] { new IdentityBinding("girl6_3", "崆峒_小蘭_幼年") }, null, "white"),
            new RoleBinding("tang-moling", "sister", "angry1 close_eye close_eye_laugh gamer laugh1 laugh3 nervous1 nervous2 normal one_hand proud sad2 shy special1 special2 special3",
                new[] { new IdentityBinding("sister1", "唐門_小師妹") },
                new[] { new IdentityBinding("sister1_look", "唐門_小師妹瞪") }, null, "one_hand"),
            new RoleBinding("long-xiang", "girl4_龍湘", "angry1 angry3 angry4 black close_eyes diffident doubt drumstick drumstick_sword hurt hurt2 laugh1 laugh2 nervous1 nervous2 nervous3 normal sad sad2 shy shy2 sword",
                new[] { new IdentityBinding("girl4", "錦香_龍湘"), new IdentityBinding("girl4_1", "錦香_龍湘_隱") },
                new[] { new IdentityBinding("girl4_2", "錦香_龍湘_宮裝") }, null, "black"),
            new RoleBinding("yu-xiaomei", "girl5_小梅", "angry1 angry2 angry3 backstage black gloomy2 hurt kick laugh1 laugh2 laugh3 nervous1 nervous2 nervous3 normal norseblood proud sad1 scary scary_laugh scary_shock shy1 shy2 shy3 shy4 special5 special5_2 special6",
                new[] { new IdentityBinding("girl5", "崆峒_小梅") },
                new[] {
                    new IdentityBinding("girl5_hand", "崆峒_小小梅手"), new IdentityBinding("girl5_9", "崆峒_小梅_入魔"), new IdentityBinding("girl5_6", "崆峒_小梅_公子"),
                    new IdentityBinding("girl5_10_1", "崆峒_小梅_分身1"), new IdentityBinding("girl5_10_2", "崆峒_小梅_分身2"), new IdentityBinding("girl5_10_3", "崆峒_小梅_分身3"),
                    new IdentityBinding("girl5_10_4", "崆峒_小梅_分身4"), new IdentityBinding("girl5_10_5", "崆峒_小梅_分身5"), new IdentityBinding("girl5_10_6", "崆峒_小梅_分身6"),
                    new IdentityBinding("girl5_7", "崆峒_小梅_半"), new IdentityBinding("girl5_2", "崆峒_小梅_夜行"), new IdentityBinding("girl5_5", "崆峒_小梅_大師兄"),
                    new IdentityBinding("girl5_4", "崆峒_小梅_幼年"), new IdentityBinding("girl5_8", "崆峒_小梅_幼年2"), new IdentityBinding("girl5_3", "崆峒_小梅_飛賊") }, null, "black special5 special5_2"),
            new RoleBinding("tang-zheng", "brother2", "angry1 angry2 close_eye close_eye_nervous gloomy1 gloomy2 hurt laugh1 laugh2 nervous1 nervous2 normal",
                new[] { new IdentityBinding("brother2", "唐門_二師兄") },
                new[] { new IdentityBinding("brother2_young", "唐門_二師兄_少年") })
        };

        internal static RoleBinding BindingFor(string role) { return Bindings.FirstOrDefault(x => x.Id == role); }

        private static IdentityBinding IdentityFor(string id, string objectName, out RoleBinding binding)
        {
            foreach (RoleBinding candidate in Bindings)
                foreach (IdentityBinding identity in candidate.Identities)
                    if (identity.Id == id && identity.Name == objectName) { binding = candidate; return identity; }
            binding = null; return null;
        }

        internal static string RoleForIdentity(string id, string objectName)
        {
            RoleBinding binding;
            return IdentityFor(id, objectName, out binding) == null ? null : binding.Id;
        }

        internal static bool AllowsExpression(string role, string expression)
        {
            RoleBinding binding = BindingFor(role);
            return binding != null && binding.HasExpression(expression);
        }

        internal static string ExpressionForAsset(string role, string canonicalPath)
        {
            RoleBinding binding = BindingFor(role);
            return binding == null ? null : binding.Expression(canonicalPath);
        }

        internal static string ExpressionForIdentityAsset(string id, string objectName, string canonicalPath)
        {
            RoleBinding binding;
            IdentityBinding identity = IdentityFor(id, objectName, out binding);
            return identity == null || !identity.Allows(canonicalPath) ? null : binding.Expression(canonicalPath);
        }

        internal static HashSet<string> EnabledRoles(CharacterConfiguration configuration)
        {
            if (configuration == null || configuration.Characters == null)
                throw new InvalidDataException("characters.json requires a supported schema and a complete character selection.");
            string[] expected = configuration.SchemaVersion == 1 ? LegacyRoleIds : configuration.SchemaVersion == 2 ? RoleIds : null;
            if (expected == null || configuration.Characters.Length != expected.Length)
                throw new InvalidDataException("characters.json must contain exactly three legacy entries for SchemaVersion 1 or seven entries for SchemaVersion 2.");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var enabled = new HashSet<string>(StringComparer.Ordinal);
            foreach (CharacterSelection selection in configuration.Characters)
            {
                if (selection == null || !expected.Contains(selection.Id, StringComparer.Ordinal) || !seen.Add(selection.Id))
                    throw new InvalidDataException("characters.json contains an unknown or duplicate character Id.");
                if (selection.Enabled) enabled.Add(selection.Id);
            }
            return enabled;
        }

        internal static string PortraitDirectory(string role)
        {
            if (role == "player") return "Portraits";
            if (RoleIds.Contains(role, StringComparer.Ordinal)) return "Characters/" + role + "/Portraits";
            throw new InvalidDataException("Unknown character Id.");
        }

        internal static string LayoutPath(string role)
        {
            if (role == "player") return "portrait-layout.tsv";
            if (RoleIds.Contains(role, StringComparer.Ordinal)) return "Characters/" + role + "/portrait-layout.tsv";
            throw new InvalidDataException("Unknown character Id.");
        }

        internal static string ContainedPath(string root, string relative)
        {
            if (string.IsNullOrEmpty(relative) || Path.IsPathRooted(relative) || relative.IndexOf(':') >= 0 || relative.IndexOf('\0') >= 0)
                throw new InvalidDataException("Unsafe portrait path.");
            string[] segments = relative.Replace('\\', '/').Split('/');
            if (segments.Any(x => x.Length == 0 || x == "." || x == ".." || x.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
                throw new InvalidDataException("Unsafe portrait path.");
            string basePath = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string result = Path.GetFullPath(Path.Combine(basePath, Path.Combine(segments)));
            if (!result.StartsWith(basePath, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Portrait path escapes its character directory.");
            for (string current = result; !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Portrait paths cannot contain a symbolic link or junction.");
            return result;
        }
    }
}
