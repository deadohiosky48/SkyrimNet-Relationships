# Static libraries, DYNAMIC CRT (/MD). See CMakeLists.txt for why this plugin
# is /MD when Kinship, its template, is /MT.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
