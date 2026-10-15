function result = fovRegion(entity, ~, ~)
%fovRegion The atlas region at the entity's FOV position (fov_ml, fov_ap), as Python's fov_region
    ml = entity.get("fov_ml", []);
    ap = entity.get("fov_ap", []);
    region = [];
    if ~isempty(ml) && ~isempty(ap) && isnumeric(ml) && isnumeric(ap) && ~isnan(ml) && ~isnan(ap)
        root = fileparts(fileparts(fileparts(mfilename("fullpath"))));
        atlas = jsondecode(nansen.internal.readText(fullfile(root, "atlas", "dorsal_cortex.json")));
        region = ophys.internal.atlasRegion(atlas, double(ml), double(ap));
    end
    result = struct("brain_region", region);
end
