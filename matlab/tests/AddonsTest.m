classdef AddonsTest < matlab.unittest.TestCase
%AddonsTest The add-on manager: declared add-ons listed, a GitHub add-on unpacked, put on the path and removed

    properties
        Folder string
    end

    methods (TestMethodSetup)
        function makeFolder(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
        end
    end

    methods (Test)
        function listsWhatTheBuiltInModulesDeclare(testCase)
            catalog = nansen.Catalog(fullfile(testCase.Folder, "catalog.json"));
            api = nansen.Api(Catalog=catalog);
            api.handle(struct("id", 1, "method", "settings.save", "params", ...
                struct("settings", struct("addons", struct("folder", char(fullfile(testCase.Folder, "addons")))))));
            response = api.handle(struct("id", 2, "method", "addons.list", "params", struct()));
            listing = response.result;
            testCase.verifyEqual(string(listing.folder), fullfile(testCase.Folder, "addons"));
            ids = string(cellfun(@(a) a.id, listing.addons, UniformOutput=false));
            testCase.verifyTrue(all(ismember(["normcorre", "suite2p", "caiman"], ids)));
            caiman = listing.addons{ids == "caiman"};
            testCase.verifyFalse(caiman.installable);
            testCase.verifyTrue(contains(caiman.how, "conda install -c conda-forge caiman"));
            response = api.handle(struct("id", 3, "method", "addons.install", "params", struct("id", "caiman")));
            testCase.verifyEqual(response.error.code, 'install-failed');
            response = api.handle(struct("id", 4, "method", "addons.install", "params", struct("id", "nothing")));
            testCase.verifyEqual(response.error.code, 'unknown-addon');
        end

        function unpacksPutsOnThePathAndRemoves(testCase)
            % a zip like GitHub's: one folder with the repository's files, and a setup script
            source = fullfile(testCase.Folder, "src", "Probe-main");
            mkdir(fullfile(source, "sub"));
            nansen.internal.writeText(fullfile(source, "nansenAddonProbe.m"), "function x = nansenAddonProbe()" + newline + "x = 42;" + newline + "end" + newline);
            nansen.internal.writeText(fullfile(source, "sub", "nansenAddonProbeHelper.m"), "function nansenAddonProbeHelper()" + newline + "end" + newline);
            nansen.internal.writeText(fullfile(source, "setupProbe.m"), "nansen.internal.writeText(fullfile(pwd, 'setup-ran.txt'), 'yes');" + newline);
            archive = fullfile(testCase.Folder, "probe.zip");
            zip(archive, "Probe-main", fullfile(testCase.Folder, "src"));
            addon = struct("id", "probe", "title", "Probe", "language", "matlab", "source", struct("github", "someone/probe"), ...
                "check", "nansenAddonProbe", "setup", "setupProbe.m");
            folder = fullfile(testCase.Folder, "addons");
            testCase.addTeardown(@() rmpath(genpath(char(folder))));
            location = nansen.Addons.install(addon, folder, archive);
            testCase.verifyEqual(string(location), fullfile(folder, "probe"));
            testCase.verifyEqual(nansenAddonProbe(), 42);
            testCase.verifyNotEmpty(which("nansenAddonProbeHelper"));
            testCase.verifyTrue(isfile(fullfile(location, "setup-ran.txt")));
            status = nansen.Addons.status(addon, folder);
            testCase.verifyTrue(status.installed);
            testCase.verifyTrue(status.removable);
            nansen.Addons.remove(addon, folder);
            testCase.verifyFalse(isfolder(location));
            testCase.verifyEmpty(which("nansenAddonProbe"));
            testCase.verifyError(@() nansen.Addons.remove(addon, folder), "nansen:InstallFailed");
        end
    end
end
