"""The add-on manager: what modules declare, downloaded and removed, pip packages, and conda ones explained."""

import io
import json
import zipfile

import pytest

from nansen import addons
from nansen.api import Api
from nansen.catalog import Catalog
from nansen.demo import create_demo
from nansen.errors import NansenError


@pytest.fixture
def api(tmp_path):
    api = Api(catalog=Catalog(tmp_path / "catalog.json"), start_queue=False)
    api.handle({"id": 1, "method": "settings.save", "params": {"settings": {"addons": {"folder": str(tmp_path / "addons")}}}})
    yield api
    api.close()


def call(api, method, **params):
    response = api.handle({"id": 2, "method": method, "params": params})
    if "error" in response:
        raise NansenError(response["error"]["code"], response["error"]["message"])
    return response["result"]


def archive(tmp_path):
    """A zip like GitHub's: one folder with the repository's files."""
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as z:
        z.writestr("NoRMCorre-master/normcorre.m", "function M = normcorre(Y, options)\nM = Y;\nend\n")
        z.writestr("NoRMCorre-master/utilities/helper.m", "function helper()\nend\n")
    path = tmp_path / "normcorre.zip"
    path.write_bytes(data.getvalue())
    return path


def test_without_a_project_the_built_in_modules_add_ons_are_listed(api, tmp_path):
    listing = call(api, "addons.list")
    assert listing["folder"] == str(tmp_path / "addons") and listing["language"] == "python"
    found = {a["id"]: a for a in listing["addons"]}
    assert {"normcorre", "suite2p", "caiman", "tifffile"} <= set(found)
    assert found["normcorre"] == dict(found["normcorre"], language="matlab", source="github", installed=None, installable=True, module="ophys")
    assert found["tifffile"]["installed"] is True       # this environment has it
    assert found["caiman"]["installable"] is False and "conda install -c conda-forge caiman" in found["caiman"]["how"]


def test_download_and_remove_a_github_add_on(api, tmp_path):
    result = call(api, "addons.install", id="normcorre", archive=str(archive(tmp_path)))
    location = tmp_path / "addons" / "normcorre"
    assert result["location"] == str(location) and result["installed"] is True and result["removable"]
    assert (location / "normcorre.m").is_file() and (location / "utilities" / "helper.m").is_file()
    assert json.loads((location / addons.MARKER).read_text())["pathOrder"] == "begin"
    call(api, "addons.install", id="normcorre", archive=str(archive(tmp_path)))   # again: replaced
    assert call(api, "addons.remove", id="normcorre")["installed"] is None
    assert not location.exists()
    with pytest.raises(NansenError) as error:
        call(api, "addons.remove", id="normcorre")
    assert error.value.code == "install-failed"


def test_what_cannot_be_installed_says_why(api, tmp_path):
    for addon_id, code in (("caiman", "install-failed"), ("nothing", "unknown-addon")):
        with pytest.raises(NansenError) as error:
            call(api, "addons.install", id=addon_id)
        assert error.value.code == code
    bad = tmp_path / "bad.zip"
    bad.write_text("not a zip")
    with pytest.raises(NansenError) as error:
        call(api, "addons.install", id="normcorre", archive=str(bad))
    assert error.value.code == "install-failed"


def test_pip_add_ons_run_pip_in_this_python(tmp_path):
    addon = {"id": "x", "title": "X", "language": "python", "source": {"pip": "xpkg>=1"}, "check": "xpkg"}
    calls = []

    class Done:
        returncode, stdout, stderr = 0, "", ""

    def run(command, **kwargs):
        calls.append(command)
        return Done()

    addons.install(addon, tmp_path, run=run)
    assert calls[0][1:] == ["-m", "pip", "install", "xpkg>=1"]
    Done.returncode, Done.stderr = 1, "no such package"
    with pytest.raises(NansenError) as error:
        addons.install(addon, tmp_path, run=run)
    assert error.value.code == "install-failed" and "no such package" in error.value.message


def test_a_project_lists_its_modules_add_ons(api, tmp_path):
    call(api, "demo.create", path=str(tmp_path / "demo"))
    ids = {a["id"] for a in call(api, "addons.list")["addons"]}
    assert "normcorre" not in ids   # the demo uses the core module only, which declares none
