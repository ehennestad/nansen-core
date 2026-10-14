classdef ProjectTest < matlab.unittest.TestCase
%ProjectTest Creating and opening projects, with no global state

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
        function doc = notes()
            doc = struct("schemaType", 'nansen.fragment', "schemaVersion", '0.1.0', "id", 'notes', ...
                "version", '1.0.0', "columns", {{struct("name", 'ignore', "dataType", 'boolean', "default", false), ...
                struct("name", 'description', "dataType", 'string')}});
        end
    end

    methods (Test)
        function createOpenAndAddEntityType(testCase)
            folder = fullfile(testCase.Folder, "p");
            project = nansen.Project.create(folder, "Pilot", Title="Pilot study");
            project.addFragment(ProjectTest.notes());
            table = project.addEntityType("session", nansen.Column("session_id", "string"), Fragments="notes");
            table.addRow(struct("session_id", "s1", "description", "first"));
            table.write()

            reopened = nansen.Project.open(folder);
            testCase.verifyEqual(reopened.Name, "Pilot");
            testCase.verifyEqual(reopened.Title, "Pilot study");
            testCase.verifyEqual(reopened.EntityTypes, "session");
            sessions = reopened.table("session");
            testCase.verifyEqual(sessions.Data.session_id, "s1");
            testCase.verifyEqual(sessions.Data.ignore, false);
            testCase.verifyEqual(sessions.Data.description, "first");
        end

        function rowsAddedToAReopenedTableGetFragmentDefaults(testCase)
            project = nansen.Project.create(testCase.Folder, "A");
            project.addFragment(ProjectTest.notes());
            project.addEntityType("session", nansen.Column("session_id", "string"), Fragments="notes");
            table = nansen.Project.open(testCase.Folder).table("session");
            table.addRow(struct("session_id", "s1"));
            row = table.getRow("s1");
            testCase.verifyFalse(row.ignore);
            testCase.verifyTrue(ismissing(row.description));
        end

        function twoProjectsAreIndependent(testCase)
            a = nansen.Project.create(fullfile(testCase.Folder, "a"), "A");
            b = nansen.Project.create(fullfile(testCase.Folder, "b"), "B");
            a.addEntityType("subject", nansen.Column("subject_id", "string"));
            testCase.verifyEqual(nansen.Project.open(fullfile(testCase.Folder, "a")).EntityTypes, "subject");
            testCase.verifyEmpty(nansen.Project.open(fullfile(testCase.Folder, "b")).EntityTypes);
            testCase.verifyEmpty(b.EntityTypes);
        end

        function createRefusesAnExistingProject(testCase)
            nansen.Project.create(testCase.Folder, "A");
            testCase.verifyError(@() nansen.Project.create(testCase.Folder, "B"), "nansen:Project:Exists");
        end

        function unknownEntityTypeAndFragment(testCase)
            project = nansen.Project.create(testCase.Folder, "A");
            testCase.verifyError(@() project.table("session"), "nansen:UnknownEntityType");
            testCase.verifyError(@() project.addEntityType("session", nansen.Column("session_id", "string"), ...
                Fragments="notes"), "nansen:UnknownFragment");
            testCase.verifyEmpty(project.EntityTypes);
        end

        function failedCreateWritesNothing(testCase)
            folder = fullfile(testCase.Folder, "x");
            testCase.verifyError(@() nansen.Project.create(folder, "not a name"), "nansen:SchemaValidation");
            testCase.verifyFalse(isfolder(folder));
        end
    end
end
