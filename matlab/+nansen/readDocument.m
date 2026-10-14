function doc = readDocument(path, options)
%readDocument Read a NANSEN document: envelope, version, migration, validation
%
%   doc = nansen.readDocument(path) returns the decoded document as the
%   current version of its schema describes it. Options:
%     ExpectedType - fail unless schemaType is this type
%     Migrations   - replaces nansen.defaultMigrations()
%
%   Errors are nansen.NansenError; see nansen.checkDocument.
    arguments
        path (1,1) string
        options.ExpectedType (1,1) string = ""
        options.Migrations struct = nansen.defaultMigrations()
    end
    doc = nansen.checkDocument(nansen.internal.readJson(path), ...
        ExpectedType=options.ExpectedType, Migrations=options.Migrations, Source=path);
end
