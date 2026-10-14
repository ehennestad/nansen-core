function results = runCases(root)
%runCases Run every conformance case; a table of Case, Passed and Detail
    arguments
        root (1,1) string = nansen.conformance.casesDirectory()
    end
    cases = nansen.conformance.listCases(root);
    passed = false(numel(cases), 1);
    detail = strings(numel(cases), 1);
    for i = 1:numel(cases)
        result = nansen.conformance.runCase(cases(i), root);
        passed(i) = result.Passed;
        detail(i) = result.Detail;
    end
    results = table(cases(:), passed, detail, VariableNames=["Case", "Passed", "Detail"]);
end
