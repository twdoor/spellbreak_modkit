"""Where this machine keeps the game, the build inputs and the release outputs.

These tools read and write cooked paks, so they need three directories that are not part of any
checkout. Each one is an environment variable with a default, so a fresh machine only has to set
what it actually moved:

    EF_GAME_DIR      the Spellbreak install               ~/Games/Spellbreak
    EF_PAK_DIR       that install's Content/Paks          $EF_GAME_DIR/g3/Content/Paks
    EF_BUILDS_DIR    inputs: archived paks and zips       ~/Games/spellbreak-builds
    EF_RELEASES_DIR  outputs: one folder per build         $EF_BUILDS_DIR/releases

The game install is only ever READ. Builds are written under EF_RELEASES_DIR, never into the repo
and never into the install.
"""
import os
from pathlib import Path


def _dir(var, default):
    return Path(os.path.expanduser(os.environ.get(var) or default))


GAME_DIR = _dir('EF_GAME_DIR', '~/Games/Spellbreak')
CONTENT_DIR = GAME_DIR / 'g3' / 'Content'
PAK_DIR = _dir('EF_PAK_DIR', str(CONTENT_DIR / 'Paks'))
BUILDS_DIR = _dir('EF_BUILDS_DIR', '~/Games/spellbreak-builds')
RELEASES_DIR = _dir('EF_RELEASES_DIR', str(BUILDS_DIR / 'releases'))

BASE_PAK = PAK_DIR / 'g3-WindowsNoEditor.pak'        # the shipped game, read only
BALANCE_PAK = PAK_DIR / 'ElefracBalance_P.pak'       # the live balance pak as installed


def release(name):
    """The folder one build reads from or writes to, e.g. release('7.0.0-lev-rc')."""
    return RELEASES_DIR / f'release-{name}'


def build(*parts):
    """A file under the build inputs, e.g. build('elefracbalance-live-preloc.pak')."""
    return BUILDS_DIR.joinpath(*parts)
