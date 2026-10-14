function writeJson(path, doc)
%writeJson Write a struct as pretty-printed JSON with a final newline
    arguments
        path (1,1) string
        doc
    end
    nansen.internal.writeText(path, [jsonencode(doc, PrettyPrint=true), newline])
end
