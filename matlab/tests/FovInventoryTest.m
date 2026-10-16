classdef FovInventoryTest < matlab.unittest.TestCase
%FovInventoryTest NANSEN dev's FOV inventories (fovmanager's Save Fov Inventory): read, planned onto the FOV map, imported

    properties
        Folder string
    end

    methods (TestMethodSetup)
        function makeFolder(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
        end
    end

    methods (Static)
        function path = casePath(varargin)
            % A file of the fov-inventory conformance case (its project, and the inventories in data/)
            path = fullfile(nansen.internal.repoRoot(), "conformance", "api", "fov-inventory", varargin{:});
        end

        function values = channel(image)
            % The red values of an image of an inventory, row after row
            pixels = double(matlab.net.base64decode(string(image.pixels)));
            values = pixels(1:3:end);
        end
    end

    methods (Test)
        function aMatFileOfStructsIsReadAsFovmanagerShowedIt(testCase)
            inventory = nansen.internal.jsonRoundTrip(nansen.legacy.exportFovInventory(FovInventoryTest.casePath("data", "inventory.mat")));
            mice = nansen.internal.asCellOfStructs(inventory.mice);
            testCase.verifyEqual(cellfun(@(m) string(m.mouseId), mice), ["1234", "1235", "4321"]);
            testCase.verifyEqual(string(mice{1}.headbarLabel), "HB-7");
            windows = nansen.internal.asCellOfStructs(mice{1}.windows);
            window = windows{1};
            testCase.verifyEqual(string(window.shape), "Round 2.5mm");
            testCase.verifyEqual(reshape(window.center, 1, []), [2, -2.5]);
            testCase.verifyEqual(window.rotation, 90);
            testCase.verifyEqual(window.edge, [3.4, -2.5; 2, -1.1; 0.6, -2.5; 2, -3.9]);
            % the photo upside down from how it was kept (MATLAB draws row 1 at the bottom of the map)
            testCase.verifyEqual([window.image.width, window.image.height], [3, 2]);
            testCase.verifyEqual(double(matlab.net.base64decode(string(window.image.pixels))), ...
                [repmat(128, 1, 9), 255, 0, 0, 0, 255, 0, 0, 0, 255]);
            fovs = nansen.internal.asCellOfStructs(window.fovs);
            testCase.verifyEqual(string(fovs{1}.sessions), "m1234-s1");
            testCase.verifyEqual(reshape(string(fovs{2}.sessions), 1, []), ["m1234-s2", "m1234-s3"]);   % by id, and current
            % doubles scaled from 0 to 1 (NaN as 0), mirrored left to right, upside down
            testCase.verifyEqual(FovInventoryTest.channel(fovs{1}.sessionImages.image), [0, 255, 128, 0]);
            % a logical image (0 and 255) turned a quarter clockwise (imrotate by theta -90, rot90 three times), upside down
            testCase.verifyEqual([fovs{2}.image.width, fovs{2}.image.height], [2, 3]);
            testCase.verifyEqual(FovInventoryTest.channel(fovs{2}.image), [255, 0, 255, 0, 0, 255]);
            injection = nansen.internal.asCellOfStructs(mice{1}.injections);
            testCase.verifyEqual(string(injection{1}.depth), "300");   % as typed
            testCase.verifyEqual(injection{1}.spread, 400);
            testCase.verifyEqual(string(mice{1}.annotations.name), "blood vessel");
            testCase.verifyError(@() nansen.legacy.exportFovInventory(FovInventoryTest.casePath("data", "not_an_inventory.mat")), ...
                "nansen:InvalidData");
        end

        function fovmanagersObjectsAreReadToo(testCase)
            % An inventory saved with fovmanager's objects in it, read with dev's classes there (here: two of them)
            classes = fullfile(testCase.Folder, "dev", "+fovmanager", "+mapobject");
            mkdir(classes);
            nansen.internal.writeText(fullfile(classes, "BaseObject.m"), strjoin([ ...
                "classdef BaseObject < handle", "    properties", "        center", "        shape", "        edge", ...
                "        image", "        alpha", "        orientation", "    end", "end"], newline) + newline);
            nansen.internal.writeText(fullfile(classes, "Annotation.m"), strjoin([ ...
                "classdef Annotation < fovmanager.mapobject.BaseObject", "    properties", "        name", "        color", ...
                "        radius", "    end", "end"], newline) + newline);
            addpath(fullfile(testCase.Folder, "dev"));
            testCase.addTeardown(@() rmpath(fullfile(testCase.Folder, "dev")));
            annotation = feval("fovmanager.mapobject.Annotation");
            annotation.center = [1.5, -2];
            annotation.name = 'vessel';
            annotation.color = 'r';
            fovDb = struct("MouseId", '7', "HeadbarLabel", 'A', "Windows", struct([]), "Injections", struct([]), ...
                "Annotations", annotation); %#ok<NASGU>
            file = fullfile(testCase.Folder, "inventory.mat");
            save(file, "fovDb");
            out = fullfile(testCase.Folder, "inventory.json");
            nansen.legacy.exportFovInventory(file, File=out);
            inventory = nansen.legacy.readFovInventory(out);   % the JSON, which Python imports too
            testCase.verifyEqual(string(inventory.mice.annotations.name), "vessel");
            testCase.verifyEqual(reshape(inventory.mice.annotations.center, 1, []), [1.5, -2]);
        end

        function aWindowsOutlineIsKeptWhenItIsNotItsShapesOwn(testCase)
            subjects = {struct("subject_id", 'm7')};
            plan = @(window) nansen.legacy.planFovInventory(struct("schemaType", 'nansen.legacyFovInventory', ...
                "schemaVersion", '0.1.0', "mice", {{struct("mouseId", '7', "headbarLabel", '', "windows", {{window}}, ...
                "injections", {{}}, "annotations", {{}})}}), {}, subjects);
            window = @(shape, edge, center, rotation) struct("shape", shape, "center", center, "edge", {num2cell(edge, 2)'}, ...
                "rotation", rotation, "fovs", {{}});
            circle = [1.25, 0; 0, 1.25; -1.25, 0; 0, -1.25];
            testCase.verifyEmpty(plan(window('Round 2.5mm', circle, [0, 0], 0)).marks.outlines);
            outlines = plan(window('Round 2.5mm', [2, 1; 1, 2.5; 0, 1; 1, -0.5], [1, 1], 0)).marks.outlines;
            testCase.verifyEqual(outlines{1}.ellipse, [1, 1.5]);
            trapezoid = [-1.5, 2.5; -2.5, -2.5; 2.5, -2.5; 1.5, 2.5] + [1, -1];   % dev's own, closed or not
            testCase.verifyEmpty(plan(window('Trapezoidal 3x5mm', trapezoid, [1, -1], 0)).marks.outlines);
            testCase.verifyEmpty(plan(window('Custom Trapezoid', [trapezoid; trapezoid(1, :)], [1, -1], 0)).marks.outlines);
            planned = plan(window('Custom Trapezoid', [0, 0; 2, 0; 1, 3], [1, 1], 45));
            testCase.verifyEqual(cell2mat(planned.marks.outlines{1}.polygon'), [-1, -1; 1, -1; 0, 2]);
            % dev's theta turns clockwise; the map's rotation is counterclockwise
            testCase.verifyEqual(planned.windows{1}.values, struct("window_ml", 1, "window_ap", 1, ...
                "window_shape", 'trapezoid 3 x 5 mm', "window_rotation", 315));
        end

        function imagesAreWrittenAs24BitBmpFiles(testCase)
            file = fullfile(testCase.Folder, "a", "image.bmp");
            nansen.legacy.writeFovImage(file, struct("width", 1, "height", 2, "pixels", matlab.net.base64encode(uint8(1:6))));
            handle = fopen(file, "r");
            bytes = fread(handle, Inf, "*uint8")';
            fclose(handle);
            testCase.verifyEqual(char(bytes(1:2)), 'BM');
            testCase.verifyEqual(numel(bytes), 62);
            testCase.verifyEqual(bytes(55:end), uint8([6, 5, 4, 0, 3, 2, 1, 0]));   % from the bottom, blue first, padded
        end

        function theAppImportsAnInventoryAndKeepsTheOtherMarks(testCase)
            copyfile(FovInventoryTest.casePath("project"), fullfile(testCase.Folder, "project"));
            api = nansen.Api(Project=nansen.Project.open(fullfile(testCase.Folder, "project")));
            saved = '{"injections": [], "notes": [], "photos": [{"id": 4, "subject": {"subject_id": "m9"}, "path": "a.png", "dataLocation": null, "width": 3, "opacity": 0.7}]}';
            api.handle(struct("id", 1, "method", "modules.saveData", "params", struct("module", "ophys", "name", "fovmap", "text", saved)));
            request = struct("id", 2, "method", "legacy.importFovInventory", ...
                "params", struct("path", FovInventoryTest.casePath("data", "inventory.mat")));
            report = api.handle(request).result;
            testCase.verifyEqual([report.injections, report.photos, report.revision], [2, 3, 2]);
            text = string(api.handle(struct("id", 3, "method", "modules.data", "params", struct("module", "ophys", "name", "fovmap"))).result.text);
            testCase.verifySubstring(text, '"dataLocation":null');   % the marks of other subjects as they were
            marks = jsondecode(text);
            photos = nansen.internal.asCellOfStructs(marks.photos);
            testCase.verifyEqual(cellfun(@(p) p.id, photos), [4, 5, 6, 7]);
            again = api.handle(request).result;
            testCase.verifyEqual(again.revision, 3);
            testCase.verifyEqual(string(api.handle(struct("id", 4, "method", "modules.data", "params", ...
                struct("module", "ophys", "name", "fovmap"))).result.text), text);
            rows = nansen.internal.asCellOfStructs(api.handle(struct("id", 5, "method", "entities.list", ...
                "params", struct("entityType", "session"))).result.rows);
            testCase.verifyEqual(string(rows{1}.values.brain_region), "V1");
        end
    end
end
