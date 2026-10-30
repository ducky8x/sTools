# The filter behind mask_home in scripts/lib/mask-home.sh, which says what it hides and why.
#
# Reads lines on standard input and prints them with the home folder shortened to ~ and every name hidden. The names come
# from the environment, not from options, so they never show up in a process list:
#   MASK_HOME          the home folder
#   MASK_ACCOUNT       the account name
#   MASK_FULL_NAME     the full name, such as "First Last"
#   MASK_HOME_NAME     the home folder's name
#   MASK_EXTRA_NAMES   more full names, one per line (the tests' made-up ones)

# Remembers one value to hide, in any letter case, and what to print in its place. The first placeholder given for a
# value is kept.
function remember(value, placeholder,    key, i) {
    key = tolower(value)
    if (length(key) == 0) return
    for (i = 1; i <= count; i++) if (lowered[i] == key) return
    count++
    lowered[count] = key
    holder[count] = placeholder
    size[count] = length(key)
}

# A full name as it is, in both orders and run together with the usual separators (a space, none, a dot, an underscore, a
# hyphen; last name first also after a comma), and each part of it of three letters or more on its own.
function remember_name(name, placeholder,    parts, n, i, words, w, kind, glue, forward, backward) {
    n = split(name, parts, /[ \t,]+/)
    w = 0
    for (i = 1; i <= n; i++) if (length(parts[i]) > 0) words[++w] = parts[i]
    if (w == 0) return
    remember(name, placeholder)
    if (w > 1) {
        for (kind = 1; kind <= 5; kind++) {
            glue = (kind == 1) ? " " : (kind == 2) ? "" : (kind == 3) ? "." : (kind == 4) ? "_" : "-"
            forward = words[1]
            for (i = 2; i <= w; i++) forward = forward glue words[i]
            backward = words[w]
            for (i = w - 1; i >= 1; i--) backward = backward glue words[i]
            remember(forward, placeholder)
            remember(backward, placeholder)
        }
        backward = words[w]
        for (i = w - 1; i >= 1; i--) backward = backward ", " words[i]
        remember(backward, placeholder)
    }
    for (i = 1; i <= w; i++) if (length(words[i]) >= 3) remember(words[i], placeholder)
}

# Longest first, so that where two names start at the same place the longer one is the one hidden.
function sort_by_size(    i, j, key, text, width) {
    for (i = 2; i <= count; i++) {
        key = lowered[i]; text = holder[i]; width = size[i]
        for (j = i - 1; j >= 1 && size[j] < width; j--) {
            lowered[j + 1] = lowered[j]; holder[j + 1] = holder[j]; size[j + 1] = size[j]
        }
        lowered[j + 1] = key; holder[j + 1] = text; size[j + 1] = width
    }
}

# Whether the name of this size found at `at` in `low` (the line in lower case) may be hidden. A name of six letters or
# more is hidden wherever it is. A shorter one only as a word of its own, with no letter right before or after it:
# hidden inside longer words too, it would show which of their letters it is.
function hideable(low, at, width) {
    if (width >= 6) return 1
    return (at == 1 || substr(low, at - 1, 1) !~ /[a-z]/) && substr(low, at + width, 1) !~ /[a-z]/
}

BEGIN {
    home = ENVIRON["MASK_HOME"]
    remember(ENVIRON["MASK_ACCOUNT"], "<account name>")
    remember_name(ENVIRON["MASK_FULL_NAME"], "<full name>")
    if (length(ENVIRON["MASK_HOME_NAME"]) >= 3) remember(ENVIRON["MASK_HOME_NAME"], "<home folder name>")
    extras = split(ENVIRON["MASK_EXTRA_NAMES"], extra, "\n")
    for (i = 1; i <= extras; i++) remember_name(extra[i], "<extra name>")
    sort_by_size()
}

{
    line = $0
    while (length(home) > 1 && (at = index(line, home)) > 0) {
        line = substr(line, 1, at - 1) "~" substr(line, at + length(home))
    }
    # One pass from left to right: the next name to hide is the one that starts first, and what is printed in its place
    # is never searched again, so a name that is also a word in a placeholder ("name", "home") cannot garble one.
    out = ""
    while (count > 0) {
        low = tolower(line)
        first = 0
        for (i = 1; i <= count; i++) {
            from = 1
            while ((at = index(substr(low, from), lowered[i])) > 0) {
                at += from - 1
                if (hideable(low, at, size[i])) {
                    if (first == 0 || at < first) { first = at; chosen = i }
                    break
                }
                from = at + 1
            }
        }
        if (first == 0) break
        out = out substr(line, 1, first - 1) holder[chosen]
        line = substr(line, first + size[chosen])
    }
    print out line
    fflush()
}
