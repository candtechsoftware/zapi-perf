# API Performance Tester
A high-performance HTTP load testing tool written in Zig. This tool allows you to test multiple endpoints concurrently with configurable thread and connection counts.

## Features
- Concurrent request execution using thread pools
- Configurable connection pooling
- Support for multiple endpoints
- Custom headers and request bodies
- JSON configuration for endpoints
- Detailed performance metrics

## Installation
1. Install the latest version of Zig (as of March 19, 2024) from [ziglang.org/download](https://ziglang.org/download/)
2. Clone the repository:
```bash
git clone https://github.com/yourusername/api-performance-tester.git
cd api-performance-tester
zig build -Doptimize=ReleaseFast
```
## Usage
```
api-perf-tester [options]

Options:
  -h, --help                Print this help message
  -f, --file=<path>         JSON file containing endpoints
  --thread-count=<num>      Number of threads to use
  --connection-count=<num>   Number of connections to use
  --request-count=<num>      Number of requests per endpoint
```

## Endpoint Configuration 

Config schema 
```json
[
  {
    "url": "string",           // Required: Full URL including query parameters
    "method": "string",        // Required: HTTP method (GET, POST, PUT, DELETE, etc.)
    "headers": {              // Optional: Request headers
      "key": "value"
    },
    "body": "string|object"   // Optional: Request body (string or JSON object)
  }
]

```
### Example 
```json 
[
  {
    "url": "https://httpbin.org/post",
    "method": "POST",
    "headers": {
      "Content-Type": "application/json"
    },
    "body": ""
  }
]
```
## Environment Variables
The application currently implements a basic environment variable substitution for Bearer token authentication. When the header `Authorization: Bearer <API_PERF_JWT>` is detected in the endpoint configuration, the `<API_PERF_JWT>` placeholder will be dynamically replaced with the value from the corresponding environment variable.

Required environment variables:
- `API_PERF_JWT`: Authentication token value that will be injected into the Bearer token header pattern. This environment variable must be set when testing endpoints that require Bearer token authentication.

Note: The current implementation is limited to Bearer token substitution. Future releases will introduce a more sophisticated token management system, including dynamic token generation, rotation, and support for multiple authentication schemes.
