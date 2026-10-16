function inventory = readFovInventory(path)
%readFovInventory A FOV inventory of NANSEN dev's fovmanager as a nansen.legacyFovInventory document
%
%   inventory = nansen.legacy.readFovInventory(path) reads the .mat file of
%   fovmanager's Save Fov Inventory (nansen.legacy.exportFovInventory), or
%   the JSON of one: a nansen.legacyFovInventory document, or a
%   nansen.legacyExport with one (fovInventory). As Python's
%   nansen.fovinventory.read_inventory: file-not-found, unsupported-file for
%   a file of another type, invalid-data for an export without an inventory.
    arguments
        path (1,1) string
    end
    if ~isfile(path)
        nansen.internal.throwError("file-not-found", "no file %s", path)
    end
    [~, name, extension] = fileparts(path);
    switch lower(extension)
        case ".json"
            inventory = nansen.internal.readJson(path);
            if isstruct(inventory) && isscalar(inventory) && ...
                    string(nansen.internal.getField(inventory, "schemaType", "")) == "nansen.legacyExport"
                if ~isfield(inventory, "fovInventory")
                    nansen.internal.throwError("invalid-data", "%s is a legacy export without a FOV inventory", name + extension)
                end
                inventory = inventory.fovInventory;
            end
            nansen.checkDocument(inventory, ExpectedType="nansen.legacyFovInventory", Source=path, Decoded=true);
        case ".mat"
            inventory = nansen.legacy.exportFovInventory(path);
        otherwise
            nansen.internal.throwError("unsupported-file", ...
                "%s: a FOV inventory is a .mat file of dev's fovmanager, or its JSON export", name + extension)
    end
end
