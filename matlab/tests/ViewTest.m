classdef ViewTest < matlab.unittest.TestCase
%ViewTest Viewing without a project: nansen.view registers files and arrays (nansen.Viewables), and the Api's
%view.frame, view.signal and view.traces serve those only. Tested on the Api, with no display.

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

        function anArrayIsViewedWithItsRoisReadOnly(testCase)
            viewables = nansen.Viewables();
            id = viewables.addStack(ViewTest.movie(), Name="movie", Rois=ViewTest.rois(), FrameRate=10);
            api = nansen.Api(Viewables=viewables);
            listed = ViewTest.call(api, "view.list").result;
            testCase.verifyEqual(listed{1}, struct("id", 'v1', "kind", 'stack', "name", 'movie', "path", '', "rois", true));
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
    end
end
