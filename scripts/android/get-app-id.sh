#!/bin/bash
# Extract applicationId from build.gradle.kts
grep "applicationId = " platforms/android/app/build.gradle.kts | sed 's/.*applicationId = "\(.*\)".*/\1/'