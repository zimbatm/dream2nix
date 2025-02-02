import json
import os
import subprocess as sp
import sys
import tempfile

from cleo import Command, argument, option

from utils import config
from nix_ffi import callNixFunction, buildNixFunction


class UpdateCommand(Command):
  description = (
    f"Update an existing package in {config['repoName']}"
  )

  name = "update"

  arguments = [
    argument(
      "name",
      "name of the package or path containing a dream-lock.json",
    ),
  ]

  options = [
    option("updater", None, "name of the updater module to use", flag=False),
    option("to-version", None, "target package version", flag=False),
  ]

  def handle(self):
    if self.io.is_interactive():
      self.line(f"\n{self.description}\n")

    # handle if package name given
    if config['packagesDir'] and '/' not in self.argument("name"):
      dreamLockFile =\
        os.path.abspath(
          f"{config['packagesDir']}/{self.argument('name')}/dream-lock.json")
      attribute_name = self.argument('name')

    # handle if path to dream-lock.json given
    else:
      dreamLockFile = os.path.abspath(self.argument("name"))
      if not dreamLockFile.endswith('dream-lock.json'):
        dreamLockFile = os.path.abspath(dreamLockFile + "/dream-lock.json")
      attribute_name = dreamLockFile.split('/')[-2]

    # parse dream lock
    with open(dreamLockFile) as f:
      lock = json.load(f)

    # find right updater
    updater = self.option('updater')
    if not updater:
      updater = callNixFunction("updaters.getUpdaterName", dreamLock=dreamLockFile)
      if updater is None:
        print(
          f"Could not find updater for this package. Specify manually via --updater",
          file=sys.stderr,
        )
        exit(1)
    print(f"updater module is: {updater}")

    # find new version
    oldPackage = lock['_generic']['defaultPackage']
    old_version = lock['_generic']['packages'][oldPackage]
    version = self.option('to-version')
    if not version:
      update_script = buildNixFunction(
        "updaters.makeUpdateScript",
        dreamLock=dreamLockFile,
        updater=updater,
      )
      update_proc = sp.run([f"{update_script}"], capture_output=True)
      version = update_proc.stdout.decode().strip()
    print(f"Updating from version {old_version} to {version}")

    cli_py = os.path.abspath(f"{__file__}/../../cli.py")
    # delete the hash
    defaultPackage = lock['_generic']['defaultPackage']
    defaultPackageVersion = lock['_generic']['packages'][defaultPackage]
    mainPackageSource = lock['sources'][defaultPackage][defaultPackageVersion]
    mainPackageSource.update(dict(
      pname = defaultPackage,
      version = defaultPackageVersion,
    ))
    updatedSourceSpec = callNixFunction(
      "fetchers.updateSource",
      source=mainPackageSource,
      newVersion=version,
    )
    lock['sources'][defaultPackage][defaultPackageVersion] = updatedSourceSpec
    with tempfile.NamedTemporaryFile("w", suffix="dream-lock.json") as tmpDreamLock:
      json.dump(lock, tmpDreamLock, indent=2)
      tmpDreamLock.seek(0)  # flushes write cache
      sp.run(
        [
          sys.executable, f"{cli_py}", "add", tmpDreamLock.name,
          "--force",
          "--no-default-nix",
          "--target", os.path.abspath(os.path.dirname(dreamLockFile)),
          "--attribute-name", attribute_name
        ]
        + lock['_generic']['translatorParams'].split()
      )
