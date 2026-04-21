using System;

namespace SqlBackupTools.Helpers
{
    // Quoting helpers for the T-SQL strings built by the restore/drop runners.
    // Database names and file paths come from directory names on disk and are
    // treated as untrusted input at the backup ingest boundary.
    public static class SqlIdentifier
    {
        // Quote a name for a bracketed identifier context, e.g. [foo].
        // Doubles any ']' and rejects control characters / nulls which have no
        // legitimate place in a SQL Server object name.
        public static string BracketQuote(string name)
        {
            EnsureNoControlChars(name);
            return "[" + name.Replace("]", "]]") + "]";
        }

        // Quote a value for a Unicode N'...' literal context. Doubles any '.
        public static string NQuote(string value)
        {
            EnsureNoControlChars(value);
            return "N'" + (value ?? string.Empty).Replace("'", "''") + "'";
        }

        // Quote a value for an ASCII '...' literal context. Doubles any '.
        public static string Quote(string value)
        {
            EnsureNoControlChars(value);
            return "'" + (value ?? string.Empty).Replace("'", "''") + "'";
        }

        private static void EnsureNoControlChars(string s)
        {
            if (string.IsNullOrEmpty(s))
                throw new ArgumentException("SQL identifier or literal is null or empty.");
            if (s.Length > 260)
                throw new ArgumentException($"SQL identifier or literal is longer than 260 chars: '{s[..Math.Min(40, s.Length)]}...'");
            foreach (var c in s)
            {
                if (c == '\0' || (c < 32 && c != '\t'))
                    throw new ArgumentException($"SQL identifier or literal contains a control character (0x{(int)c:X2}).");
            }
        }
    }
}
