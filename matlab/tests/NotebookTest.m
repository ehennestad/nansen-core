classdef NotebookTest < matlab.unittest.TestCase
%NotebookTest Notes on entities, as Python's test_notebook checks them

    properties
        Notebook
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.Project.create(fullfile(fixture.Folder, "p"), "P");
            project.addEntityType("session", [nansen.Column("session_id", "string"), nansen.Column("run", "integer")]);
            testCase.Notebook = project.notebook("session");
        end
    end

    methods (Test)
        function tagsAreAsciiWordsInOrderEachOnce(testCase)
            testCase.verifyEqual(nansen.Notebook.tagsOf("Bad #motion", "see #z-drift and #motion, #é #a_1"), ...
                ["motion", "z", "a_1"]);
        end

        function notesAreNewestFirstAndIdsAreNotReused(testCase)
            notebook = testCase.Notebook;
            first = notebook.add(struct("session_id", "s1", "run", 1), "first", Author="ana");
            second = notebook.add(struct("run", 2, "session_id", "s1"), "second", Title="Run #2", Type="todo", Author="ana");
            testCase.verifyEqual([first.id, second.id], [1, 2]);
            testCase.verifyEqual(string(fieldnames(second.key))', ["session_id", "run"]);
            testCase.verifyEqual(second.tags, {'2'});
            testCase.verifyEqual(cellfun(@(n) n.id, notebook.notes()), [2, 1]);
            testCase.verifyEqual(cellfun(@(n) n.id, notebook.notes(struct("session_id", "s1", "run", 1))), 1);
            notebook.remove(2);
            third = notebook.add(struct("session_id", "s1", "run", 1), "third", Author="ana");
            testCase.verifyEqual(third.id, 3);
            document = jsondecode(fileread(notebook.Path));
            testCase.verifyEqual(document.nextId, 4);
            testCase.verifyEqual([document.notes.id], [1, 3]);   % the file keeps writing order
            notes = notebook.notes();
            testCase.verifyEmpty(notes{1}.tags);
            testCase.verifyClass(notes{1}.tags, "cell");
        end

        function badKeysTypesAndEmptyNotesAreRefused(testCase)
            notebook = testCase.Notebook;
            keys = {struct("session_id", "s1"), struct("session_id", "s1", "run", 1, "x", 1), ...
                struct("session_id", "s1", "run", true), "s1"};
            for i = 1:numel(keys)
                testCase.verifyError(@() notebook.add(keys{i}, "text"), "nansen:InvalidParams");
            end
            key = struct("session_id", "s1", "run", 1);
            testCase.verifyError(@() notebook.add(key, "text", Type="urgent"), "nansen:InvalidParams");
            testCase.verifyError(@() notebook.add(key, " "), "nansen:InvalidParams");
            testCase.verifyError(@() notebook.remove(7), "nansen:UnknownNote");
        end
    end
end
