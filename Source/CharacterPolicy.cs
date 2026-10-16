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
        internal static readonly string[] RoleIds = { "player", "tang-buyi", "xiahou-lan" };
        internal const string AssetRoot = "assets/__project/images/characters/";
        private static readonly HashSet<string> PlayerExpressions = Words("angry1 angry2 angry3 blood blood_laugh1 blood_nervous1 blood_no_weapon blood_no_weapon_laugh1 caught close_eye close_eye_laugh close_eye_nervous close_eye_nervous2 close_eye_powder determined die doubt eye_mask_nervous1 eye_mask_nervous2 fist_north_star gloomy2 god_thunder head hero_landing hurt hurt2 hurt_fist laugh1 laugh2 mask mud nervous1 nervous2 nervous3 normal oraora revel sad1 shake shake2 shock soul special1 stupid suck1 suck3 suck4");
        private static readonly HashSet<string> BrotherExpressions = Words("angry1 angry2 angry3 hand hat hurt laugh1 laugh2 nervous1 nervous2 nervous3 normal serious shock special1 suck");
        private static readonly HashSet<string> LanExpressions = Words("angry angry2 block blood cry droopy gloomy gloomy2 laugh1 love nervous nervous2 normal shy2 squint white");

        private static HashSet<string> Words(string value) { return new HashSet<string>(value.Split(' '), StringComparer.Ordinal); }

        internal static string RoleForIdentity(string id, string objectName)
        {
            if ((id == "player" && (objectName == "唐門_主角" || objectName == "唐門_主角_自戀")) ||
                (id == "player_young" && objectName == "唐門_主角_少年")) return "player";
            if ((id == "brother1" && objectName == "唐門_大師兄") ||
                (id == "brother1_2" && objectName == "唐門_大師兄2") ||
                (id == "brother1_0" && objectName == "唐門_大師兄_隱")) return "tang-buyi";
            if ((id == "girl6" && objectName == "崆峒_小蘭") || (id == "girl6_1" && objectName == "崆峒_小蘭_早")) return "xiahou-lan";
            return null;
        }

        internal static bool AllowsExpression(string role, string expression)
        {
            if (expression == null) return false;
            if (role == "player") return PlayerExpressions.Contains(expression);
            if (role == "tang-buyi") return BrotherExpressions.Contains(expression);
            if (role == "xiahou-lan") return LanExpressions.Contains(expression);
            return false;
        }

        internal static string ExpressionForAsset(string role, string canonicalPath)
        {
            if (string.IsNullOrEmpty(canonicalPath)) return null;
            string path = canonicalPath.Replace('\\', '/').ToLowerInvariant();
            string prefix = role == "player" ? AssetRoot + "player_主角/" : role == "tang-buyi" ? AssetRoot + "brother1/" : role == "xiahou-lan" ? AssetRoot + "girl6_小蘭/" : null;
            if (role == "player" && path.StartsWith(AssetRoot + "player_自戀/", StringComparison.Ordinal))
            {
                string alternative = path.Substring((AssetRoot + "player_自戀/").Length);
                if (new[] { "normal.png", "angry1.png", "laugh1.png", "nervous1.png", "nervous3.png" }.Contains(alternative, StringComparer.Ordinal))
                    return alternative.Substring(0, alternative.Length - 4);
                return null;
            }
            if (prefix == null || !path.StartsWith(prefix, StringComparison.Ordinal) || !path.EndsWith(".png", StringComparison.Ordinal)) return null;
            string expression = path.Substring(prefix.Length, path.Length - prefix.Length - 4);
            return AllowsExpression(role, expression) ? expression : null;
        }

        internal static string ExpressionForIdentityAsset(string id, string objectName, string canonicalPath)
        {
            string role = RoleForIdentity(id, objectName);
            if (role == null) return null;
            string expression = ExpressionForAsset(role, canonicalPath);
            if (id == "player_young" && (expression != "normal" || !string.Equals(canonicalPath, AssetRoot + "player_主角/normal.png", StringComparison.OrdinalIgnoreCase))) return null;
            // The early adult Lan record uses a verified subset of the base assets.
            if (id == "girl6_1" && (expression == "droopy" || expression == "squint" || expression == "white")) return null;
            return expression;
        }

        internal static HashSet<string> EnabledRoles(CharacterConfiguration configuration)
        {
            if (configuration == null || configuration.SchemaVersion != 1 || configuration.Characters == null || configuration.Characters.Length != RoleIds.Length)
                throw new InvalidDataException("characters.json must contain SchemaVersion 1 and exactly three character entries.");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var enabled = new HashSet<string>(StringComparer.Ordinal);
            foreach (CharacterSelection selection in configuration.Characters)
            {
                if (selection == null || !RoleIds.Contains(selection.Id, StringComparer.Ordinal) || !seen.Add(selection.Id))
                    throw new InvalidDataException("characters.json contains an unknown or duplicate character Id.");
                if (selection.Enabled) enabled.Add(selection.Id);
            }
            return enabled;
        }

        internal static string PortraitDirectory(string role)
        {
            if (role == "player") return "Portraits";
            if (role == "tang-buyi" || role == "xiahou-lan") return "Characters/" + role + "/Portraits";
            throw new InvalidDataException("Unknown character Id.");
        }

        internal static string LayoutPath(string role)
        {
            if (role == "player") return "portrait-layout.tsv";
            if (role == "tang-buyi" || role == "xiahou-lan") return "Characters/" + role + "/portrait-layout.tsv";
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
