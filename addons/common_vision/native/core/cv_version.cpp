#include "core/cv_version.h"

namespace cv {

std::string api_version_string() {
	return std::to_string(API_VERSION_MAJOR) + "." +
			std::to_string(API_VERSION_MINOR) + "." +
			std::to_string(API_VERSION_PATCH);
}

} // namespace cv
