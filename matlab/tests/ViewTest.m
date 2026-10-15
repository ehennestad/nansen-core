classdef ViewTest < matlab.unittest.TestCase
%ViewTest Viewing without a project: nansen.view registers files and arrays (nansen.Viewables), and the Api's
%view.frame, view.signal and view.traces serve those only; view.updateRois saves ROIs drawn on them, view.detect finds
%one around a click and view.run runs a method on them. Tested on the Api, with no display.

    properties
        Folder
    end

    methods (TestMethodSetup)
        function makeFolder(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = string(fixture.Folder);
        end
    end

    methods (Static)
        function data = movie()
            % 24 x 32 pixels, 6 frames: frame t (from 0) has value t everywhere, but a bright square in frames 2 and 3
            data = repmat(reshape(uint16(0:5), 1, 1, 6), 24, 32, 1);
            data(5:8, 5:8, 3:4) = 100;
        end

        function rois = rois()
            rois = struct("rois", {{struct("id", 1, "pixels", [4 4; 4 5; 5 4; 5 5], "classification", "accepted"), ...
                struct("id", 2, "pixels", [10 10])}});
        end

        function data = moving()
            % 32 x 32 x 8: a periodic texture moved circularly by whole pixels, frame by frame
            rng(3);
            texture = 100 + 20 * randn(32, 32);
            shifts = [0 0; 1 0; 0 -2; 2 1; -1 1; 0 0; 1 2; -2 0];
            data = zeros(32, 32, 8);
            for t = 1:8
                data(:, :, t) = circshift(texture, -shifts(t, :));
            end
        end

        function pixels = pixelsOf(roi)
            % An ROI's pixels as the Api gives them (a cell of [row, column]), as an n x 2 matrix
            pixels = cell2mat(reshape(roi.pixels, [], 1));
        end

        function response = call(api, method, params)
            if nargin < 3
                params = struct();
            end
            response = api.handle(struct("id", 1, "method", method, "params", params));
        end
    end

    methods (Test)
        function nothingIsViewableUntilRegistered(testCase)
            api = nansen.Api();
            testCase.verifyEmpty(api.Project);
            testCase.verifyEmpty(ViewTest.call(api, "view.list").result);
            for method = ["view.frame", "view.traces", "view.signal"]
                response = ViewTest.call(api, method, struct("viewable", "v1", "pixels", [0 0]));
                testCase.verifyEqual(string(response.error.code), "unknown-viewable", method);
            end
            testCase.verifyEqual(string(ViewTest.call(api, "view.frame").error.code), "invalid-params");
            response = ViewTest.call(api, "files.frame", struct("path", "anything.tif"));
            testCase.verifyEqual(string(response.error.code), "no-project");   % files are still read only in a project
            text = api.handleJson('{"id": 2, "method": "view.list"}');
            testCase.verifyEqual(string(text), "{""id"":2,""result"":[]}");
        end

        function anArrayIsViewedWithItsRois(testCase)
            viewables = nansen.Viewables();
            id = viewables.addStack(ViewTest.movie(), Name="movie", Rois=ViewTest.rois(), FrameRate=10);
            api = nansen.Api(Viewables=viewables);
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(listed{1}, struct("id", 'v1', "kind", 'stack', "name", 'movie', "path", '', "rois", true, "roiFile", ''));
            frame = ViewTest.call(api, "view.frame", struct("viewable", id, "frame", 2, "rois", true)).result;
            testCase.verifyEqual([frame.height, frame.width, frame.frames, frame.frame], [24, 32, 6, 2]);
            testCase.verifyEqual([frame.low, frame.high], [2, 100]);
            testCase.verifyEqual(frame.metadata, struct("frameRate", 10));
            testCase.verifyEqual(string(frame.name), "movie");
            testCase.verifyEqual(string(frame.adapter), "");
            testCase.verifyEmpty(frame.adapters);
            testCase.verifyEqual(cellfun(@(r) r.id, frame.rois), [1, 2]);
            testCase.verifyEqual(string(frame.rois{1}.classification), "accepted");
            testCase.verifyFalse(isfield(ViewTest.call(api, "view.frame", struct("viewable", id)).result, "rois"));
            testCase.verifyEqual(ViewTest.call(api, "view.frame", struct("viewable", id, "projection", "max")).result.high, 100);
            signal = ViewTest.call(api, "view.signal", struct("viewable", id, "pixels", [4 4; 5 5])).result;
            testCase.verifyEqual(signal.traces{1}.columns{1}.values, {0, 1, 100, 100, 4, 5});
            testCase.verifyEqual(signal.frameRate, 10);
            response = ViewTest.call(api, "view.traces", struct("viewable", id));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % a stack, not signals
            response = ViewTest.call(api, "view.frame", struct("viewable", id, "adapter", "ophys.tiff_stack"));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % an array has no file to read
        end

        function signalsArePlottedAsDataTracesGivesThem(testCase)
            viewables = nansen.Viewables();
            id = viewables.addSignals([(0:9)', -(0:9)'], Name="dff");
            api = nansen.Api(Viewables=viewables);
            traces = ViewTest.call(api, "view.traces", struct("viewable", id, "columns", [0, 1], "maxPoints", 5)).result;
            testCase.verifyEqual([traces.frames, traces.step], [10, 2]);
            testCase.verifyEmpty(traces.frameRate);
            testCase.verifyEqual(string(traces.traces{1}.variable), "dff");
            testCase.verifyEqual(traces.traces{1}.count, 2);
            testCase.verifyEqual(traces.traces{1}.columns{2}.values, {0, -2, -4, -6, -8});
            response = ViewTest.call(api, "view.traces", struct("viewable", id, "columns", 2));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = ViewTest.call(api, "view.frame", struct("viewable", id));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % signals, not a stack
            testCase.verifyError(@() viewables.addSignals(zeros(2, 2, 2)), "nansen:InvalidData");
        end

        function filesAreReadByTheirAdapters(testCase)
            movie = fullfile(testCase.Folder, "movie.npy");
            nansen.adapters.Npy().write(movie, ViewTest.movie());
            dff = fullfile(testCase.Folder, "dff.npy");
            nansen.adapters.Npy().write(dff, ones(6, 3));
            rois = fullfile(testCase.Folder, "rois.json");
            nansen.internal.writeText(rois, jsonencode(ViewTest.rois()));
            viewables = nansen.Viewables();
            ids = viewables.register(movie, Rois=rois, Signals=dff);
            testCase.verifyEqual(ids, ["v1", "v2"]);
            api = nansen.Api(Viewables=viewables);
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(string(cellfun(@(v) v.name, listed, UniformOutput=false)), ["movie.npy", "dff"]);
            testCase.verifyEqual(string(cellfun(@(v) v.kind, listed, UniformOutput=false)), ["stack", "signals"]);
            testCase.verifyTrue(endsWith(string(listed{1}.path), filesep + "movie.npy"));   % the full path
            frame = ViewTest.call(api, "view.frame", struct("viewable", "v1", "frame", 3, "rois", true)).result;
            testCase.verifyEqual([frame.height, frame.width, frame.frames, frame.high], [24, 32, 6, 100]);
            testCase.verifyEqual(string(frame.adapter), "npy");
            testCase.verifyEqual(string(frame.adapters), "npy");
            testCase.verifyEqual(numel(frame.rois), 2);
            response = ViewTest.call(api, "view.frame", struct("viewable", "v1", "adapter", "ophys.tiff_stack"));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % not one of its candidates
            testCase.verifyEqual(ViewTest.call(api, "view.traces", struct("viewable", "v2")).result.traces{1}.count, 3);
        end

        function whatCannotBeViewedIsRefusedWhenRegistered(testCase)
            viewables = nansen.Viewables();
            testCase.verifyError(@() viewables.addStack(fullfile(testCase.Folder, "missing.tif")), "nansen:FileNotFound");
            testCase.verifyError(@() viewables.addStack(zeros(1, 5)), "nansen:InvalidData");
            testCase.verifyError(@() viewables.addStack({1, 2}), "nansen:InvalidData");
            notes = fullfile(testCase.Folder, "notes.txt");
            nansen.internal.writeText(notes, "text");
            testCase.verifyError(@() viewables.addStack(notes), "nansen:UnsupportedFile");
            testCase.verifyError(@() viewables.addStack(ViewTest.movie(), Rois=struct("rois", "not a list")), "nansen:InvalidData");
            testCase.verifyError(@() viewables.register([]), "nansen:InvalidParams");
            testCase.verifyEqual(viewables.count(), 0);
        end

        function aMatFileNamesTheSignalsVariable(testCase)
            path = fullfile(testCase.Folder, "signals.mat");
            dff = ones(8, 2);
            spikes = zeros(8, 2);
            note = 'text';
            save(path, "dff", "spikes", "note");
            viewables = nansen.Viewables();
            testCase.verifyError(@() viewables.addSignals(path), "nansen:InvalidParams");   % two numeric arrays: which?
            id = viewables.addSignals(path, Variable="spikes");
            item = viewables.get(id);
            testCase.verifyEqual(item.name, "signals.spikes");
            api = nansen.Api(Viewables=viewables);
            testCase.verifyEqual(ViewTest.call(api, "view.traces", struct("viewable", id)).result.traces{1}.count, 2);
        end

        function roisDrawnOnAFileAreSavedBesideItAndReadAgain(testCase)
            movie = fullfile(testCase.Folder, "movie.npy");
            nansen.adapters.Npy().write(movie, ViewTest.movie());
            viewables = nansen.Viewables();
            viewables.register(movie);
            api = nansen.Api(Viewables=viewables);
            beside = fullfile(testCase.Folder, "movie_rois.json");
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(string(listed{1}.roiFile), string(beside));
            testCase.verifyFalse(isfile(beside));
            testCase.verifyEmpty(ViewTest.call(api, "view.frame", struct("viewable", "v1", "rois", true)).result.rois);   % none yet
            square = [4 4; 4 5; 5 4; 5 5];
            added = ViewTest.call(api, "view.updateRois", struct("viewable", "v1", "imageSize", [24 32], ...
                "add", {{struct("pixels", square)}})).result;
            testCase.verifyEqual(numel(added.added), 1);
            testCase.verifyEqual(string(added.file), string(beside));
            changed = ViewTest.call(api, "view.updateRois", struct("viewable", "v1", ...
                "classify", struct("id", 1, "classification", "accepted"))).result;
            testCase.verifyEqual(string(changed.rois{1}.classification), "accepted");
            saved = jsondecode(fileread(beside));
            testCase.verifyEqual(reshape(saved.imageSize, 1, []), [24, 32]);
            testCase.verifyEqual(saved.rois.pixels, square);
            testCase.verifyEqual(string(saved.rois.classification), "accepted");
            testCase.verifyTrue(ViewTest.call(api, "view.list").result{1}.rois);
            moved = ViewTest.call(api, "view.updateRois", struct("viewable", "v1", "move", struct("id", 1, "rows", 2, "columns", 0))).result;
            testCase.verifyEqual(ViewTest.pixelsOf(moved.rois{1}), [6 4; 6 5; 7 4; 7 5]);
            response = ViewTest.call(api, "view.updateRois", struct("viewable", "v1", "mirror", true));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % aligned with nothing
            % viewed again with no ROIs given: the ones saved beside it
            again = nansen.Viewables();
            again.register(movie);
            frame = ViewTest.call(nansen.Api(Viewables=again), "view.frame", struct("viewable", "v1", "rois", true)).result;
            testCase.verifyEqual(ViewTest.pixelsOf(frame.rois{1}), [6 4; 6 5; 7 4; 7 5]);
        end

        function roisGivenInAFileAreSavedBackAndAnArraysKeptInMemory(testCase)
            movie = fullfile(testCase.Folder, "movie.npy");
            nansen.adapters.Npy().write(movie, ViewTest.movie());
            curated = fullfile(testCase.Folder, "curated.json");
            nansen.internal.writeText(curated, jsonencode(ViewTest.rois()));
            viewables = nansen.Viewables();
            viewables.addStack(movie, Rois=curated);
            viewables.addStack(ViewTest.movie(), Name="array");
            viewables.addSignals(ones(6, 2), Name="dff");
            api = nansen.Api(Viewables=viewables);
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(string(cellfun(@(v) v.roiFile, listed, UniformOutput=false)), [string(curated), "", ""]);
            result = ViewTest.call(api, "view.updateRois", struct("viewable", "v1", "remove", 2)).result;
            testCase.verifyEqual(string(result.file), string(curated));
            saved = jsondecode(fileread(curated));
            testCase.verifyEqual([saved.rois.id], 1);
            % an array's ROIs are kept while the app runs; one viewable's ROIs are imported into another's
            imported = ViewTest.call(api, "view.updateRois", struct("viewable", "v2", "import", struct("viewable", "v1", "mode", "append"))).result;
            testCase.verifyEqual(string(imported.file), "");
            testCase.verifyEqual(numel(imported.added), 1);
            frame = ViewTest.call(api, "view.frame", struct("viewable", "v2", "rois", true)).result;
            testCase.verifyEqual(ViewTest.pixelsOf(frame.rois{1}), [4 4; 4 5; 5 4; 5 5]);
            listing = dir(testCase.Folder);
            testCase.verifyEqual(sort(string({listing(~[listing.isdir]).name})), ["curated.json", "movie.npy"]);
            response = ViewTest.call(api, "view.updateRois", struct("viewable", "v2", "import", struct("variable", "RoiArray")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = ViewTest.call(api, "view.updateRois", struct("viewable", "v3", "add", {{struct("pixels", [1 1])}}));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % signals
        end

        function detectFindsTheCellAroundAClick(testCase)
            viewables = nansen.Viewables();
            viewables.addStack(ViewTest.movie());
            api = nansen.Api(Viewables=viewables);
            found = ViewTest.call(api, "view.detect", struct("viewable", "v1", "point", [5 6], "radius", 4)).result;
            [rows, columns] = ndgrid(4:7, 4:7);
            testCase.verifyEqual(sortrows(cell2mat(reshape(found.pixels, [], 1))), sortrows([rows(:), columns(:)]));
            response = ViewTest.call(api, "view.detect", struct("viewable", "v1", "point", [30 0]));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function aMethodRunsOnAFileAndWhatItSavesIsViewable(testCase)
            rec = fullfile(testCase.Folder, "rec.npy");
            nansen.adapters.Npy().write(rec, ViewTest.moving());
            viewables = nansen.Viewables();
            viewables.addStack(rec, FrameRate=15);
            api = nansen.Api(Viewables=viewables);
            listed = string(cellfun(@(m) m.id, ViewTest.call(api, "view.methods").result, UniformOutput=false));
            testCase.verifyTrue(all(ismember(["ophys.motion_correction", "ophys.detect_rois", "ophys.extract_signals"], listed)));
            testCase.verifyFalse(any(ismember(["ophys.setup_variables", "ophys.compute_dff"], listed)));   % a tool; no stack
            run = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", "ophys.motion_correction", ...
                "options", struct("maxShift", 4, "referenceFrames", 1))).result;
            testCase.verifyEqual(double([run.result.frames, run.result.maxShift]), [8, 2]);
            testCase.verifyEqual(double(run.result.meanShift), 1.3608, AbsTol=1e-9);
            aligned = fullfile(testCase.Folder, "rec_TwoPhotonSeries_Corrected.npy");
            testCase.verifyEqual(string(run.outputs{1}.path), string(aligned));
            testCase.verifyEqual(string(run.outputs{1}.kind) + "/" + string(run.outputs{1}.viewable), "stack/v2");
            testCase.verifyEqual(string(run.outputs{2}.path), string(fullfile(testCase.Folder, "rec_MotionCorrectionShifts.npy")));
            testCase.verifyEqual(string(run.outputs{2}.kind), "data");
            data = ViewTest.moving();
            values = nansen.adapters.Npy().read(aligned);
            testCase.verifyEqual(values(5:end - 4, 5:end - 4, :), repmat(data(5:end - 4, 5:end - 4, 1), 1, 1, 8), AbsTol=1e-9);
            second = ViewTest.call(api, "view.list").result{2};
            testCase.verifyEqual(string(second.name), "rec.npy · TwoPhotonSeries_Corrected");
            testCase.verifyEqual(string(second.roiFile), string(fullfile(testCase.Folder, "rec_TwoPhotonSeries_Corrected_rois.json")));
            frame = ViewTest.call(api, "view.frame", struct("viewable", "v2", "projection", "std")).result;
            testCase.verifyEqual(frame.frames, 8);
            testCase.verifyEqual(string(frame.adapter), "npy");
            testCase.verifyEqual(frame.metadata, struct("frameRate", 15));
            % run again: the aligned stack is read again, under the same id
            again = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", "ophys.motion_correction", ...
                "preset", "default", "options", struct("maxShift", 4))).result;
            testCase.verifyEqual(string(again.outputs{1}.viewable), "v2");
            testCase.verifyEqual(viewables.count(), 2);
            % ROI detection on the aligned stack: the ROIs found are viewable over it; signals are extracted with its ROIs
            ViewTest.call(api, "view.updateRois", struct("viewable", "v2", "imageSize", [32 32], ...
                "add", {{struct("pixels", [10 10; 10 11; 11 10; 11 11])}}));
            found = ViewTest.call(api, "view.run", struct("viewable", "v2", "methodId", "ophys.detect_rois", ...
                "options", struct("threshold", 0.99, "border", 4))).result;
            testCase.verifyEqual(string(found.outputs{1}.kind) + "/" + string(found.outputs{1}.viewable), "rois/v3");
            third = ViewTest.call(api, "view.list").result{3};
            testCase.verifyEqual(string(third.path), string(aligned));
            testCase.verifyEqual(string(third.roiFile), string(fullfile(testCase.Folder, "rec_TwoPhotonSeries_Corrected_RoiArray.json")));
            signals = ViewTest.call(api, "view.run", struct("viewable", "v2", "methodId", "ophys.extract_signals")).result;
            testCase.verifyNotEmpty(signals.outputs);
            response = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", "ophys.extract_signals"));
            testCase.verifyEqual(string(response.error.code), "data-not-found");   % v1 has no ROIs
            % what cannot run on a viewable
            methodIds = ["ophys.nothing", "ophys.setup_variables", "ophys.compute_dff"];
            codes = ["unknown-method", "wrong-entity-type", "invalid-params"];
            for i = 1:numel(methodIds)
                response = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", methodIds(i)));
                testCase.verifyEqual(string(response.error.code), codes(i), methodIds(i));
            end
            response = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", "ophys.motion_correction", ...
                "options", struct("maxShift", -1)));
            testCase.verifyEqual(string(response.error.code), "invalid-options");
        end

        function aMethodRunOnAnArrayKeepsWhatItSavesInMemory(testCase)
            viewables = nansen.Viewables();
            viewables.addStack(ViewTest.moving(), Name="movie");
            api = nansen.Api(Viewables=viewables);
            run = ViewTest.call(api, "view.run", struct("viewable", "v1", "methodId", "ophys.motion_correction", ...
                "options", struct("maxShift", 4, "referenceFrames", 1))).result;
            testCase.verifyEqual(string(cellfun(@(o) o.path, run.outputs, UniformOutput=false)), ["", ""]);
            testCase.verifyEqual(string(cellfun(@(o) o.viewable, run.outputs, UniformOutput=false)), ["v2", ""]);
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(string(listed{2}.name), "movie · TwoPhotonSeries_Corrected");
            testCase.verifyEqual(ViewTest.call(api, "view.frame", struct("viewable", "v2", "frame", 3)).result.frames, 8);
        end
    end
end
