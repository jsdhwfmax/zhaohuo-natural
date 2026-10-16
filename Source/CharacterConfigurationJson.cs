namespace ZhaoHuoNatural
{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Text;

    // Configuration belongs to the plugin, not Unity's native serialization system.
    // Parse this small, closed schema in managed code so injected assemblies behave
    // identically inside Unity Mono and in the standalone configuration tests.
    internal sealed class CharacterConfigurationJson
    {
        private readonly string text;
        private int position;

        private CharacterConfigurationJson(string text) { this.text = text; }

        internal static CharacterConfiguration Parse(string text)
        {
            if (text == null || text.Length == 0 || text.Length > 65536)
                throw new InvalidDataException("characters.json is empty or too large.");
            var parser = new CharacterConfigurationJson(text);
            if (text[0] == '\uFEFF') parser.position++;
            CharacterConfiguration result = parser.Configuration();
            parser.Space();
            if (parser.position != text.Length) throw parser.Invalid("Trailing JSON content");
            // Identity/count validation stays shared with the runtime scope policy.
            CharacterPolicy.EnabledRoles(result);
            return result;
        }

        private CharacterConfiguration Configuration()
        {
            Expect('{');
            var result = new CharacterConfiguration();
            bool schema = false, characters = false;
            if (Take('}')) throw Invalid("Required configuration fields missing");
            do
            {
                string key = String(); Expect(':');
                if (key == "SchemaVersion" && !schema)
                {
                    Expect('1'); result.SchemaVersion = 1; schema = true;
                }
                else if (key == "Characters" && !characters)
                {
                    result.Characters = Selections(); characters = true;
                }
                else throw Invalid("Unknown or duplicate configuration field");
            } while (Take(','));
            Expect('}');
            if (!schema || !characters) throw Invalid("Required configuration fields missing");
            return result;
        }

        private CharacterSelection[] Selections()
        {
            Expect('[');
            var result = new List<CharacterSelection>();
            if (Take(']')) return result.ToArray();
            do
            {
                if (result.Count >= CharacterPolicy.RoleIds.Length) throw Invalid("Too many character entries");
                Expect('{');
                var selection = new CharacterSelection();
                bool id = false, enabled = false;
                if (Take('}')) throw Invalid("Required character fields missing");
                do
                {
                    string key = String(); Expect(':');
                    if (key == "Id" && !id) { selection.Id = String(); id = true; }
                    else if (key == "Enabled" && !enabled) { selection.Enabled = Boolean(); enabled = true; }
                    else throw Invalid("Unknown or duplicate character field");
                } while (Take(','));
                Expect('}');
                if (!id || !enabled) throw Invalid("Required character fields missing");
                result.Add(selection);
            } while (Take(','));
            Expect(']');
            return result.ToArray();
        }

        private bool Boolean()
        {
            Space();
            if (Literal("true")) return true;
            if (Literal("false")) return false;
            throw Invalid("Enabled must be a JSON boolean");
        }

        private bool Literal(string value)
        {
            if (position + value.Length > text.Length || string.CompareOrdinal(text, position, value, 0, value.Length) != 0) return false;
            position += value.Length; return true;
        }

        private string String()
        {
            Expect('"');
            var result = new StringBuilder();
            while (position < text.Length)
            {
                char c = text[position++];
                if (c == '"') return result.ToString();
                if (c < 0x20) throw Invalid("Unescaped control character");
                if (c != '\\') { result.Append(c); continue; }
                if (position == text.Length) throw Invalid("Incomplete string escape");
                c = text[position++];
                switch (c)
                {
                    case '"': case '\\': case '/': result.Append(c); break;
                    case 'b': result.Append('\b'); break;
                    case 'f': result.Append('\f'); break;
                    case 'n': result.Append('\n'); break;
                    case 'r': result.Append('\r'); break;
                    case 't': result.Append('\t'); break;
                    case 'u':
                        int code = 0;
                        for (int i = 0; i < 4; i++)
                        {
                            if (position == text.Length) throw Invalid("Incomplete Unicode escape");
                            char digit = text[position++];
                            int value = digit >= '0' && digit <= '9' ? digit - '0' : digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 : digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : -1;
                            if (value < 0) throw Invalid("Invalid Unicode escape");
                            code = code * 16 + value;
                        }
                        result.Append((char)code); break;
                    default: throw Invalid("Invalid string escape");
                }
            }
            throw Invalid("Unterminated JSON string");
        }

        private void Space()
        {
            while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++;
        }
        private bool Take(char value)
        {
            Space();
            if (position >= text.Length || text[position] != value) return false;
            position++; return true;
        }
        private void Expect(char value) { if (!Take(value)) throw Invalid("Expected JSON token"); }
        private InvalidDataException Invalid(string reason) { return new InvalidDataException(reason + " at character " + position + "."); }
    }
}
