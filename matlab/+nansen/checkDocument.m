function doc = checkDocument(doc, options)
%checkDocument Check a decoded document's envelope, migrate it and validate it
%
%   doc = nansen.checkDocument(doc) raises nansen.NansenError with
%   code unknown-schema-type, unsupported-version or schema-validation, and
%   otherwise returns the document as the current schema version describes it.
%
%   doc can also be a struct built in MATLAB: it is validated as it would be
%   written, after a round trip through jsonencode and jsondecode.
    arguments
        doc
        options.ExpectedType (1,1) string = ""
        options.Migrations struct = nansen.defaultMigrations()
        options.Source (1,1) string = "document"
    end
    source = options.Source;
    fail = @(code, format, varargin) nansen.internal.throwError(code, "%s: " + format, source, varargin{:});

    if ~(isstruct(doc) && isscalar(doc))
        fail("unknown-schema-type", "a document must be a JSON object")
    end
    schemaType = nansen.internal.getField(doc, "schemaType", []);
    entry = [];
    if (ischar(schemaType) && isrow(schemaType)) || (isstring(schemaType) && isscalar(schemaType))
        entry = nansen.internal.schemaEntry(char(schemaType));
    end
    if isempty(entry)
        fail("unknown-schema-type", "unknown schemaType")
    end
    schemaType = string(schemaType);
    if options.ExpectedType ~= "" && schemaType ~= options.ExpectedType
        fail("unknown-schema-type", "expected a %s document, got %s", options.ExpectedType, schemaType)
    end

    doc = migrate(doc, schemaType, string(entry.version), options.Migrations, fail);

    decoded = jsondecode(jsonencode(doc));
    errors = nansen.internal.schemaValidationErrors(decoded, nansen.internal.loadSchema(schemaType));
    if ~isempty(errors)
        fail("schema-validation", "%s", strjoin(errors, "; "))
    end
end

function doc = migrate(doc, schemaType, currentText, migrations, fail)
    version = nansen.internal.parseVersion(nansen.internal.getField(doc, "schemaVersion", []));
    current = nansen.internal.parseVersion(currentText);
    if isempty(version)
        fail("unsupported-version", "schemaVersion is not MAJOR.MINOR.PATCH")
    end
    if nansen.internal.versionLess(current(1:2), version(1:2))
        fail("unsupported-version", "%s %s is newer than this reader (%s)", schemaType, doc.schemaVersion, currentText)
    end
    step = sprintf("%d.%d", version(1), version(2));
    target = sprintf("%d.%d", current(1), current(2));
    while step ~= target
        match = find(arrayfun(@(m) string(m.SchemaType) == schemaType && string(m.FromVersion) == step, migrations), 1);
        if isempty(match)
            fail("unsupported-version", "no migration for %s from %s", schemaType, step)
        end
        migration = migrations(match);
        next = string(migration.ToVersion);
        if ~nansen.internal.versionLess(nansen.internal.parseVersion(step + ".0"), ...
                nansen.internal.parseVersion(next + ".0"))
            fail("unsupported-version", "migration for %s from %s does not move forward", schemaType, step)
        end
        doc = migration.Apply(doc);
        step = next;
        doc.schemaVersion = char(step + ".0");
    end
end
