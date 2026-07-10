## PROJECT GOAL
The purpose of this project is to create a wrapper for the FITS (1.6.0) project, written in JRuby, that runs a Unix socket and processes files and outputs the XML.

## Constraints
Project is JRuby only (currently jruby-9.4.15.0) due to the Java version being >= 17 in this case. Needs to run lightweight with minimal JVM heap and take filepaths as inputs or be able to stream large binary in from large files IF possible.

Test driven development with rspec is a must

## Git
Only the current developer may push commits or set/change git remotes/origins. Claude may create local commits and branches as needed, but must never push or configure remotes.

## OTHER
FITS 1.6.0 is installed at `~/tools/fits-1.6.0`; refer to its README.md and CHANGELOG.md for FITS documentation.
