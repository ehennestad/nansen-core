classdef DocumentTest < matlab.unittest.TestCase
%DocumentTest Envelope checks, migration and validation of documents built in MATLAB

    methods (Static)
        function doc = project(varargin)
            doc = struct("schemaType", 'nansen.project', "schemaVersion", '0.1.0', "name", 'P', "entityTypes", {{}});
            for i = 1:2:numel(varargin)
                doc.(varargin{i}) = varargin{i + 1};
            end
        end

        function migration = migration(schemaType, from, to, apply)
            migration = struct("SchemaType", schemaType, "FromVersion", from, "ToVersion", to, "Apply", apply);
        end
    end

    methods (Test)
        function validDocumentIsReturned(testCase)
            doc = nansen.checkDocument(DocumentTest.project());
            testCase.verifyEqual(string(doc.name), "P");
        end

        function expectedTypeIsEnforced(testCase)
            testCase.verifyError(@() nansen.checkDocument(DocumentTest.project(), ExpectedType="nansen.table"), ...
                "nansen:UnknownSchemaType");
        end

        function migrationChainRunsAndSetsTheVersion(testCase)
            old = struct("schemaType", 'nansen.project', "schemaVersion", '0.0.4', "projectName", 'Old', "entityTypes", {{}});
            migration = DocumentTest.migration("nansen.project", "0.0", "0.1", @renameProjectName);
            doc = nansen.checkDocument(old, Migrations=migration);
            testCase.verifyEqual(string(doc.name), "Old");
            testCase.verifyEqual(string(doc.schemaVersion), "0.1.0");
            testCase.verifyFalse(isfield(doc, "projectName"));
        end

        function migrationForAnotherTypeIsNotUsed(testCase)
            migration = DocumentTest.migration("nansen.table", "0.0", "0.1", @(d) d);
            testCase.verifyError(@() nansen.checkDocument(DocumentTest.project("schemaVersion", '0.0.1'), ...
                Migrations=migration), "nansen:UnsupportedVersion");
        end

        function migrationMustMoveForward(testCase)
            migration = DocumentTest.migration("nansen.project", "0.0", "0.0", @(d) d);
            testCase.verifyError(@() nansen.checkDocument(DocumentTest.project("schemaVersion", '0.0.1'), ...
                Migrations=migration), "nansen:UnsupportedVersion");
        end

        function migratedDocumentIsStillValidated(testCase)
            migration = DocumentTest.migration("nansen.project", "0.0", "0.1", @addExtraField);
            testCase.verifyError(@() nansen.checkDocument(DocumentTest.project("schemaVersion", '0.0.1'), ...
                Migrations=migration), "nansen:SchemaValidation");
        end

        function errorCarriesItsCode(testCase)
            try
                nansen.checkDocument(DocumentTest.project("name", '2 bad'));
                testCase.verifyFail("expected an error");
            catch err
                testCase.verifyClass(err, "nansen.NansenError");
                testCase.verifyEqual(err.Code, "schema-validation");
                testCase.verifyEqual(string(err.identifier), "nansen:SchemaValidation");
            end
        end

        function missingFileIsReported(testCase)
            testCase.verifyError(@() nansen.readDocument(fullfile(tempdir, "no-such-nansen-file.json")), ...
                "nansen:FileNotFound");
        end

        function formatNumberRoundTrips(testCase)
            stream = RandStream("mt19937ar", Seed=0);
            values = [(rand(stream, 1, 500) - 0.5) * 2e6, 10 .^ (rand(stream, 1, 500) * 60 - 30), ...
                round((rand(stream, 1, 100) - 0.5) * 2e6), 100, 1.5, 0.001234, 1e20, -2.5e-7, 1e16, 1e17, 5e-324];
            for value = values
                text = nansen.formatNumber(value);
                testCase.verifyNotEmpty(regexp(text, '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$', "once"), text);
                testCase.verifyEqual(str2double(text), value, text);
            end
            testCase.verifyEqual(nansen.formatNumber(100), "100");
            testCase.verifyEqual(nansen.formatNumber(1e20), "1e+20");
            testCase.verifyEqual(nansen.formatNumber(1e16), "10000000000000000");
            testCase.verifyEqual(nansen.formatNumber(-2.5e-7), "-2.5e-07");
        end
    end
end

function doc = renameProjectName(doc)
    doc.name = doc.projectName;
    doc = rmfield(doc, "projectName");
end

function doc = addExtraField(doc)
    doc.extra = 1;
end
