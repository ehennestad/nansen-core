function entry = schemaEntry(schemaType)
%schemaEntry The index entry for a schemaType, or [] when the type is unknown
    entries = nansen.internal.schemaIndex();
    match = strcmp({entries.schemaType}, schemaType);
    if any(match)
        entry = entries(find(match, 1));
    else
        entry = [];
    end
end
