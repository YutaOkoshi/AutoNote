"""File names and Unicode forms.

AutoNote's vault files have NFD names on a Mac's disk (濁点 stored apart), while git keeps NFC names in its tree
(core.precomposeunicode). APFS opens either form as the same file, so comparing names as plain strings can take a
file for "the old name of this meeting" and delete what was just written. Everything this package writes to the
repository, the reader copy, links and state files is NFC; names read from a folder are compared after nfc().
"""
import os
import unicodedata


def nfc(s):
    return unicodedata.normalize("NFC", s or "")


def on_disk(path):
    """The path with its last component spelled as the folder lists it (maybe another Unicode form), or None."""
    d, base = os.path.split(path)
    want = nfc(base)
    try:
        names = os.listdir(d or ".")
    except OSError:
        return None
    if base in names:
        return path
    for n in names:
        if nfc(n) == want:
            return os.path.join(d, n)
    return None


def settle(path):
    """Makes the name on disk the NFC one. Returns the path to use from now on.

    A name that differs from its NFC form only by Unicode form is renamed. When both forms exist as two different
    files (a file system that tells them apart), nothing is renamed and the given path is returned.
    """
    d, base = os.path.split(path)
    want = nfc(base)
    if base == want:
        return path
    target = os.path.join(d, want)
    try:
        if os.path.lexists(target) and not os.path.samefile(path, target):
            return path
        os.rename(path, target)
    except OSError:
        return path
    return target
