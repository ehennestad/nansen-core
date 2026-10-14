classdef ConformanceTest < matlab.unittest.TestCase
%ConformanceTest The MATLAB implementation passes every conformance case

    properties (TestParameter)
        caseId = ConformanceTest.caseIds()
    end

    methods (Static)
        function ids = caseIds()
            ids = cellstr(nansen.conformance.listCases());
        end
    end

    methods (Test)
        function passesCase(testCase, caseId)
            result = nansen.conformance.runCase(caseId);
            testCase.verifyTrue(result.Passed, caseId + ": " + result.Detail);
        end

        function findsEveryKindOfCase(testCase)
            cases = nansen.conformance.listCases();
            for kind = ["documents", "tables", "projects"]
                testCase.verifyNotEmpty(cases(startsWith(cases, kind + "/")), kind);
            end
        end
    end
end
