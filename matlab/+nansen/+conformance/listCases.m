function cases = listCases(root)
%listCases Every conformance case as "kind/name", in the order the Python runner uses
    arguments
        root (1,1) string = nansen.conformance.casesDirectory()
    end
    cases = strings(1, 0);
    for kind = ["documents", "tables", "projects", "entities"]
        listing = dir(fullfile(root, kind));
        names = sort(string({listing([listing.isdir] & ~startsWith({listing.name}, ".")).name}));
        cases = [cases, kind + "/" + names]; %#ok<AGROW>
    end
end
