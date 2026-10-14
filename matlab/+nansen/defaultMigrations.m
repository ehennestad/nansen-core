function migrations = defaultMigrations()
%defaultMigrations The migrations readers apply to older documents
%
%   A struct array with fields SchemaType, FromVersion ("MAJOR.MINOR"),
%   ToVersion ("MAJOR.MINOR") and Apply (a function taking and returning the
%   decoded document). No schema has changed since 0.1, so it is empty.
    migrations = struct("SchemaType", {}, "FromVersion", {}, "ToVersion", {}, "Apply", {});
end
