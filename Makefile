__SIM_ID=`xcrun simctl list|egrep -m 1 '$(SIM_NAME) \([^(]*\) \([^(]*\)$$'|sed -e 's/.* (\(.*\)) (.*)/\1/'`
SIM_NAME=iPhone 5s
SIM_ID=$(shell echo $(__SIM_ID))

ifeq ($(strip $(SIM_ID)),)
$(error Could not find $(SIM_NAME) simulator)
endif

.PHONY: test setup lint coverage

test:
	xcodebuild test -workspace ContentfulPersistence.xcworkspace \
		-scheme ContentfulPersistence -destination 'id=$(SIM_ID)' | xcpretty -c

setup:
	bundle install
	bundle exec pod install --no-repo-update

lint:
	bundle exec pod lib lint ContentfulPersistenceSwift.podspec --verbose

coverage:
	bundle exec slather coverage -s ContentfulPersistence.xcodeproj

carthage:
	carthage build --no-skip-current
	carthage archive ContentfulPersistence
