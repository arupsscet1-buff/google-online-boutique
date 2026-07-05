FROM mcr.microsoft.com/dotnet/sdk:9.0 AS builder

ARG TARGETARCH

WORKDIR /src

COPY cartservice.csproj .

RUN dotnet restore cartservice.csproj

COPY . .

RUN dotnet publish \
    cartservice.csproj \
    -c Release \
    -o /publish \
    --no-restore


FROM mcr.microsoft.com/dotnet/aspnet:9.0-noble-chiseled

WORKDIR /app

COPY --from=builder /publish .

ENV DOTNET_EnableDiagnostics=0 \
    ASPNETCORE_HTTP_PORTS=7070

EXPOSE 7070

USER 65532

ENTRYPOINT ["dotnet","cartservice.dll"]
