function name = hdf5TypeName(type)
%hdf5TypeName The shared name of an HDF5 type (h5info's Datatype): float32, int16, uint8, string, enum, compound,
%reference or other, as Python's nansen.hdf5.data_type
    switch string(type.Class)
        case "H5T_FLOAT"
            name = "float" + string(8 * type.Size);
        case "H5T_INTEGER"
            if contains(string(type.Type), "_U")
                name = "uint" + string(8 * type.Size);
            else
                name = "int" + string(8 * type.Size);
            end
        case "H5T_STRING"
            name = "string";
        case "H5T_ENUM"
            name = "enum";
        case "H5T_COMPOUND"
            name = "compound";
        case "H5T_REFERENCE"
            name = "reference";
        otherwise
            name = "other";
    end
end
