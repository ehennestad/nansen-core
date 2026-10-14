classdef EntityTableTest < matlab.unittest.TestCase
%EntityTableTest Reading, writing and editing entity tables

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
        function table = makeTable()
            columns = [nansen.Column("subject_id", "string"), nansen.Column("session_id", "string"), ...
                nansen.Column("ignore", "boolean"), nansen.Column("depth", "number"), ...
                nansen.Column("started_at", "datetime")];
            table = nansen.EntityTable("session", ["subject_id", "session_id"], columns);
        end
    end

    methods (Test)
        function largeTableRoundTrip(testCase)
            % 20,000 rows read and written back; the times are logged, so CI shows how the reader scales.
            template = EntityTableTest.makeTable();
            table = nansen.EntityTable("session", template.Key, template.Columns, File="session.csv");
            sidecar = fullfile(testCase.Folder, "session.table.nansen.json");
            table.write(sidecar);
            n = 20000;
            i = (1:n)';
            flags = ["false"; "true"];
            lines = compose("m%03d,s%06d,", mod(i, 100), i) + flags(1 + (mod(i, 7) == 0)) + ...
                compose(",%d,2025-01-01T09:30:00.000", i);
            header = nansen.internal.readText(fullfile(testCase.Folder, "session.csv"));
            nansen.internal.writeText(fullfile(testCase.Folder, "session.csv"), string(header) + strjoin(lines, newline) + newline);
            started = tic;
            read = nansen.EntityTable.read(sidecar);
            readSeconds = toc(started);
            testCase.verifyEqual(read.numRows(), n);
            rows = read.toJsonRows();
            testCase.verifyEqual(string(rows{n}.session_id), "s020000");
            started = tic;
            read.write();
            writeSeconds = toc(started);
            testCase.log(1, sprintf("%d rows: read %.2f s, written %.2f s", n, readSeconds, writeSeconds));
        end

        function roundTripThroughFiles(testCase)
            table = EntityTableTest.makeTable();
            table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false, "depth", 12.5, ...
                "started_at", datetime(2025, 5, 10, 10, 0, 0.2509)));
            table.addRow(struct("subject_id", "m1", "session_id", "s2", "ignore", true));
            path = fullfile(testCase.Folder, "session.table.nansen.json");
            table.write(path)

            again = nansen.EntityTable.read(path);
            testCase.verifyEqual(again.numRows(), 2);
            testCase.verifyEqual(again.Data.session_id, ["s1"; "s2"]);
            testCase.verifyEqual(again.Data.ignore, [false; true]);
            testCase.verifyEqual(again.Data.depth(1), 12.5);
            testCase.verifyTrue(isnan(again.Data.depth(2)));
            testCase.verifyEqual(nansen.internal.formatDatetime(again.Data.started_at(1)), "2025-05-10T10:00:00.250");
            testCase.verifyTrue(isnat(again.Data.started_at(2)));
            testCase.verifyEqual(again.Revision, 0);
        end

        function revisionIncrementsAndConflictsAreDetected(testCase)
            path = fullfile(testCase.Folder, "session.table.nansen.json");
            EntityTableTest.makeTable().write(path)
            first = nansen.EntityTable.read(path);
            second = nansen.EntityTable.read(path);
            first.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false));
            first.write()
            testCase.verifyEqual(first.Revision, 1);
            second.addRow(struct("subject_id", "m2", "session_id", "s1", "ignore", false));
            testCase.verifyError(@() second.write(), "nansen:RevisionConflict");
            testCase.verifyEqual(nansen.EntityTable.read(path).numRows(), 1);
        end

        function writeLeavesNoTemporaryFiles(testCase)
            EntityTableTest.makeTable().write(fullfile(testCase.Folder, "session.table.nansen.json"))
            listing = dir(testCase.Folder);
            names = sort(string({listing(~[listing.isdir]).name}));
            testCase.verifyEqual(names, ["session.csv", "session.table.nansen.json"]);
        end

        function getUpdateRemove(testCase)
            table = EntityTableTest.makeTable();
            table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false));
            table.addRow(struct("subject_id", "m1", "session_id", "s2", "ignore", false));
            table.updateRow({"m1", "s2"}, struct("ignore", true, "depth", 3));
            row = table.getRow(struct("subject_id", "m1", "session_id", "s2"));
            testCase.verifyEqual(row.depth, 3);
            testCase.verifyTrue(row.ignore);
            table.removeRow(["m1", "s1"]);
            testCase.verifyEqual(table.Data.session_id, "s2");
            testCase.verifyTrue(table.hasRow({"m1", "s2"}));
            testCase.verifyFalse(table.hasRow({"m1", "s1"}));
            testCase.verifyError(@() table.updateRow({"m1", "s2"}, struct("session_id", "s3")), ...
                "nansen:ReadOnlyColumn");
        end

        function addChecksValues(testCase)
            table = EntityTableTest.makeTable();
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "ignore", false)), "nansen:MissingKey");
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s1")), "nansen:MissingValue");
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", "yes")), ...
                "nansen:InvalidValue");
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false, ...
                "depth", Inf)), "nansen:InvalidValue");
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false, ...
                "started_at", datetime(2025, 1, 1, TimeZone="UTC"))), "nansen:InvalidValue");
            testCase.verifyEqual(table.numRows(), 0);
        end

        function addRejectsDuplicatesAndUnknownColumns(testCase)
            table = EntityTableTest.makeTable();
            table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false));
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", true)), ...
                "nansen:DuplicateKey");
            testCase.verifyError(@() table.addRow(struct("subject_id", "m1", "session_id", "s9", "ignore", true, ...
                "colour", "red")), "nansen:EntityTable:UnknownColumn");
        end

        function addColumnsFillsDefaults(testCase)
            table = EntityTableTest.makeTable();
            table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false));
            table.addColumns([nansen.Column("qc", "boolean", Fragment="ophys.qc"), ...
                nansen.Column("snr", "number", Fragment="ophys.qc")], struct("qc", true), "ophys.qc", "1.0.0");
            testCase.verifyTrue(table.getRow({"m1", "s1"}).qc);
            testCase.verifyEqual(table.FragmentIds, "ophys.qc");
            table.addRow(struct("subject_id", "m1", "session_id", "s2", "ignore", false));
            testCase.verifyTrue(table.getRow({"m1", "s2"}).qc);
            testCase.verifyError(@() table.addColumns(nansen.Column("qc", "string")), "nansen:InvalidTableSpec");
        end

        function nanIsWrittenAsMissing(testCase)
            table = EntityTableTest.makeTable();
            table.addRow(struct("subject_id", "m1", "session_id", "s1", "ignore", false, "depth", NaN));
            lines = splitlines(table.toCsv());
            testCase.verifyEqual(lines(2), "m1,s1,false,,");
        end

        function parseCsvReportsQuoting(testCase)
            [records, quoted] = nansen.internal.parseCsv(['a,b', newline, '"",', newline]);
            testCase.verifyEqual(string(records{2}), ["", ""]);
            testCase.verifyEqual(quoted{2}, [true, false]);
        end
    end
end
