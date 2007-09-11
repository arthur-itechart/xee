#import "XeePhotoshopLoader.h"
#import "Xee8BIMParser.h"
#import "XeePhotoshopLayerParser.h"

#import "XeeInterleavingHandle.h"
#import "XeeRawImage.h"
#import "XeeBitmapRawImage.h"
#import "XeeIndexedRawImage.h"
#import "CSRegex.h"



@implementation XeePhotoshopImage

+(NSArray *)fileTypes
{
	return [NSArray arrayWithObjects:@"psd",@"'8BPS'",nil];
}

+(BOOL)canOpenFile:(NSString *)name firstBlock:(NSData *)block attributes:(NSDictionary *)attributes
{
	uint8 *header=(uint8 *)[block bytes];
	if([block length]>6&&XeeBEUInt32(header)=='8BPS'&&XeeBEUInt16(header+4)==1) return YES;
	return NO;
}

-(id)init
{
	if(self=[super init])
	{
	}
	return self;
}

-(void)dealloc
{
	[super dealloc];
}

-(SEL)initLoader
{
	CSHandle *fh=[self handle];

	[fh skipBytes:12];

	channels=[fh readUInt16BE];
	height=[fh readUInt32BE];
	width=[fh readUInt32BE];
	bitdepth=[fh readUInt16BE];
	mode=[fh readUInt16BE];

	// Colour data section
	uint32 colourlen=[fh readUInt32BE];
	off_t resourceoffs=[fh offsetInFile]+colourlen;

	XeePalette *pal=nil;
	if(mode==XeePhotoshopIndexedMode&&colourlen>=768)
	{
		pal=[[[XeePalette alloc] init] autorelease];
		uint8 palbuf[768];
		[fh readBytes:768 toBuffer:palbuf];
		for(int i=0;i<256;i++)
		[pal setColourAtIndex:i red:palbuf[i] green:palbuf[i+256] blue:palbuf[i+512]];
	}
	

	// Resources section
	[fh seekToFileOffset:resourceoffs];
	uint32 resourcelen=[fh readUInt32BE];
	off_t layermaskoffs=[fh offsetInFile]+resourcelen;

	Xee8BIMParser *parser=[[Xee8BIMParser alloc] initWithHandle:fh];

	NSArray *metaprops=[parser propertyArrayWithPhotoshopFirst:YES];
	BOOL hasmerged=[parser hasMergedImage];
	int numcols=[parser numberOfIndexedColours];
	int trans=[parser indexOfTransparentColour];
	if(trans>=0) [pal setTransparent:trans];

	[parser release];



	// Layers section
	[fh seekToFileOffset:layermaskoffs];
	uint32 layermasklen=[fh readUInt32BE];
	off_t imageoffs=[fh offsetInFile]+layermasklen;

	NSArray *layers=nil;
	BOOL hasalpha=NO;

	uint32 layerlen=[fh readUInt32BE];
	off_t maskoffs=[fh offsetInFile]+layerlen;

	if(layerlen>0) layers=[XeePhotoshopLayerParser parseLayersFromHandle:fh parentImage:self alphaFlag:&hasalpha];

	[fh seekToFileOffset:maskoffs];
	uint32 masklen=[fh readUInt32BE];
	[fh skipBytes:masklen];

	while([fh offsetInFile]+12<=imageoffs)
	{
		uint32 sign=[fh readUInt32BE];
		uint32 marker=[fh readUInt32BE];
		uint32 chunklen=[fh readUInt32BE];
		off_t nextchunk=[fh offsetInFile]+((chunklen+3)&~3);
		// At this point, I'd like to take a moment to speak to you about the Adobe PSD format.
		// PSD is not a good format. PSD is not even a bad format. Calling it such would be an
		// insult to other bad formats, such as PCX or JPEG. No, PSD is an abysmal format. Having
		// worked on this code for several weeks now, my hate for PSD has grown to a raging fire
		// that burns with the fierce passion of a million suns.
		// If there are two different ways of doing something, PSD will do both, in different
		// places. It will then make up three more ways no sane human would think of, and do those
		// too. PSD makes inconsistency an art form. Why, for instance, did it suddenly decide
		// that *these* particular chunks should be aligned to four bytes, and that this alignement
		// should *not* be included in the size? Other chunks in other places are either unaligned,
		// or aligned with the alignment included in the size. Here, though, it is not included.
		// Either one of these three behaviours would be fine. A sane format would pick one. PSD,
		// of course, uses all three, and more.
		// Trying to get data out of a PSD file is like trying to find something in the attic of
		// your eccentric old uncle who died in a freak freshwater shark attack on his 58th
		// birthday. That last detail may not be important for the purposes of the simile, but
		// at this point I am spending a lot of time imagining amusing fates for the people
		// responsible for this Rube Goldberg of a file format.
		// Earlier, I tried to get a hold of the latest specs for the PSD file format. To do this,
		// I had to apply to them for permission to apply to them to have them consider sending
		// me this sacred tome. This would have involved faxing them a copy of some document or
		// other, probably signed in blood. I can only imagine that they make this process so
		// difficult because they are intensely ashamed of having created this abomination. I
		// was naturally not gullible enough to go through with this procedure, but if I had done
		// so, I would have printed out every single page of the spec, and set them all on fire.
		// Were it within my power, I would gather every single copy of those specs, and launch
		// them on a spaceship directly into the sun.
		//
		// PSD is not my favourite file format.

		if(sign!='8BIM') break; // sanity check

		switch(marker)
		{
			case 'Lr16':
				layers=[XeePhotoshopLayerParser parseLayersFromHandle:fh parentImage:self alphaFlag:NULL];
			break;

			case 'Mt16':
				hasalpha=YES;
			break;

			case 'Anno':
			{
				if([fh readUInt16BE]!=2) break;
				if([fh readUInt16BE]!=1) break;

				int numanno=[fh readUInt32BE];
				NSMutableArray *annotations=[NSMutableArray array];

				for(int i=0;i<numanno;i++)
				{
					uint32 annolen=[fh readUInt32BE];
					off_t nextanno=[fh offsetInFile]+annolen-4;
					if([fh readUInt32BE]=='txtA')
					{
						[fh skipBytes:46];
						int len=[fh readUInt8];
						[fh skipBytes:len+((len&1)^1)];
						len=[fh readUInt8];
						[fh skipBytes:len+((len&1)^1)];
						len=[fh readUInt8];
						NSString *datestr=[[[NSString alloc] initWithData:[fh readDataOfLength:len] encoding:NSISOLatin1StringEncoding] autorelease];
						[fh skipBytes:((len&1)^1)+4];

						NSCalendarDate *date=nil;
						NSArray *matches=[datestr substringsCapturedByPattern:@"^D:([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([+-])([0-9]{2})'([0-9]{2})'$"];
						if(matches)
						{
							int year=[[matches objectAtIndex:1] intValue];
							int month=[[matches objectAtIndex:2] intValue];
							int day=[[matches objectAtIndex:3] intValue];
							int hour=[[matches objectAtIndex:4] intValue];
							int minute=[[matches objectAtIndex:5] intValue];
							int second=[[matches objectAtIndex:6] intValue];
							int tzmult=[[matches objectAtIndex:7] isEqual:@"-"]?-1:1;
							int tzhour=[[matches objectAtIndex:8] intValue];
							int tzmin=[[matches objectAtIndex:9] intValue];

							NSTimeZone *tz=[NSTimeZone timeZoneForSecondsFromGMT:tzmult*(tzhour*60+tzmin)*60];
							date=[NSCalendarDate dateWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:tz];
						}

						if([fh readUInt32BE]=='txtC')
						{
							len=[fh readUInt32BE];
							NSData *annodata=[fh readDataOfLength:len];
							const uint8 *annobytes=[annodata bytes];

							NSString *str;
							if(len>2&&annobytes[0]==0xfe&&annobytes[1]==0xff)
							str=[[[NSString alloc] initWithBytes:annobytes+2 length:len-2
							encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingUTF16BE)] autorelease];
							else str=[[[NSString alloc] initWithData:annodata encoding:NSISOLatin1StringEncoding] autorelease];

							[annotations addObjectsFromArray:[XeePropertyItem itemsWithLabel:
							NSLocalizedString(@"Annotation",@"Photoshop annotation property title")
							textValue:str]];
							[annotations addObject:[XeePropertyItem itemWithLabel:
							NSLocalizedString(@"Added at",@"Photoshop annotation date property title")
							value:date]];
						}
					}
					[fh seekToFileOffset:nextanno];
				}
				if(numanno) [properties addObject:[XeePropertyItem itemWithLabel:
				NSLocalizedString(@"Photoshop annotations",@"Photoshop annotations section title")
				value:annotations identifier:@"psanno"]];
			}
			break;
		}

		[fh seekToFileOffset:nextchunk];
	}


	switch(mode)
	{
		case XeePhotoshopBitmapMode: [self setDepthBitmap]; break;
		case XeePhotoshopGreyscaleMode: [self setDepthGrey:bitdepth alpha:hasalpha floating:bitdepth==32?YES:NO]; break;
		case XeePhotoshopIndexedMode: [self setDepthIndexed:numcols?numcols:1<<bitdepth]; break;
		case XeePhotoshopRGBMode: [self setDepthRGB:bitdepth alpha:hasalpha floating:bitdepth==32?YES:NO]; break;
		case XeePhotoshopCMYKMode: [self setDepthCMYK:bitdepth alpha:hasalpha]; break;
		case XeePhotoshopLabMode: [self setDepthLab:bitdepth alpha:hasalpha]; break;

		case XeePhotoshopMultichannelMode:
			[self setDepth:
			[NSString stringWithFormat:NSLocalizedString(@"%d bits multichannel",@"Description for multichannel (Photoshop) images"),bitdepth]
			iconName:@"depth_grey"];
		break;

		case XeePhotoshopDuotoneMode:
		 	[self setDepth:
			[NSString stringWithFormat:NSLocalizedString(@"%d bits duotone",@"Description for duotone (Photoshop) images"),bitdepth]
			iconName:@"depth_rgb"];
		break;
	}

	[properties addObjectsFromArray:metaprops];

	// Image section

	if(hasmerged)
	{
		[fh seekToFileOffset:imageoffs];

		XeeImage *mainimage=nil;
		switch(mode)
		{
			case XeePhotoshopBitmapMode:
				mainimage=[[[XeeBitmapRawImage alloc] initWithHandle:[self handleForNumberOfChannels:1 alpha:NO]
				width:width height:height parentImage:self] autorelease];
			break;

			case XeePhotoshopIndexedMode:
				mainimage=[[[XeeIndexedRawImage alloc] initWithHandle:[self handleForNumberOfChannels:1 alpha:NO]
				width:width height:height palette:pal parentImage:self] autorelease];
			break;

			case XeePhotoshopGreyscaleMode:
			case XeePhotoshopDuotoneMode:
				mainimage=[[[XeeRawImage alloc] initWithHandle:[self handleForNumberOfChannels:1 alpha:hasalpha]
				width:width height:height depth:bitdepth colourSpace:XeeGreyRawColourSpace
				flags:XeeBigEndianRawFlag|XeeAlphaPrecomposedRawFlag|(hasalpha?XeeAlphaLastRawFlag:0)|(bitdepth==32?XeeFloatingPointRawFlag:0)
				parentImage:self] autorelease];
			break;

			case XeePhotoshopRGBMode:
				mainimage=[[[XeeRawImage alloc] initWithHandle:[self handleForNumberOfChannels:3 alpha:hasalpha]
				width:width height:height depth:bitdepth colourSpace:XeeRGBRawColourSpace
				flags:XeeBigEndianRawFlag|XeeAlphaPrecomposedRawFlag|(hasalpha?XeeAlphaLastRawFlag:0)|(bitdepth==32?XeeFloatingPointRawFlag:0)
				parentImage:self] autorelease];
			break;

			case XeePhotoshopCMYKMode:
				mainimage=[[[XeeRawImage alloc] initWithHandle:[self handleForNumberOfChannels:4 alpha:hasalpha]
				width:width height:height depth:bitdepth colourSpace:XeeCMYKRawColourSpace
				flags:XeeBigEndianRawFlag|XeeAlphaPrecomposedRawFlag|(hasalpha?XeeAlphaLastRawFlag:0)
				parentImage:self] autorelease];
			break;

			case XeePhotoshopLabMode:
				mainimage=[[[XeeRawImage alloc] initWithHandle:[self handleForNumberOfChannels:3 alpha:hasalpha]
				width:width height:height depth:bitdepth colourSpace:XeeLabRawColourSpace
				flags:XeeBigEndianRawFlag|XeeAlphaPrecomposedRawFlag|(hasalpha?XeeAlphaLastRawFlag:0)
				parentImage:self] autorelease];
			break;
		}
	}

	NSEnumerator *enumerator=[layers objectEnumerator];
	XeePhotoshopLayerParser *layer;
	while(layer=[enumerator nextObject])
	{
		/*XeeImage *image=*/[layer image];
	}

	[self setFormat:@"PSD"];

	loadersel=NULL;
	loaderframe=-1;

	return @selector(load);
}

-(void)deallocLoader
{
}

-(SEL)load
{
	if(!loadersel)
	{
		if(loaderframe>=0) [[subimages objectAtIndex:loaderframe] deallocLoader];
		loaderframe++;
		if(loaderframe>=[self frames])
		{
			loaded=YES;
			return NULL;
		}
		loadersel=@selector(initLoader);
	}
	loadersel=(SEL)[[subimages objectAtIndex:loaderframe] performSelector:loadersel];
	return @selector(load);
}

-(CSHandle *)handleForNumberOfChannels:(int)requiredchannels alpha:(BOOL)alpha;
{
	int numchannels=requiredchannels+(alpha?1:0);
	if(numchannels>channels) return nil;

	NSMutableArray *array=[NSMutableArray array];
	off_t totalsize=0;
	int bpr=(bitdepth*width+7)/8;

	int compression=[handle readUInt16BE];
	switch(compression)
	{
		case 0:
			for(int i=0;i<numchannels;i++)
			{
				CSFileHandle *fh=[[handle copy] autorelease];
				[fh skipBytes:i*bpr*height];
				[array addObject:fh];
			}
		break;

		case 1:
			for(int i=0;i<numchannels;i++)
			{
				XeePackbitsHandle *ph=[[[XeePackbitsHandle alloc] initWithHandle:[[handle copy] autorelease]
				rows:height bytesPerRow:bpr channel:i of:channels previousSize:totalsize] autorelease];
				totalsize+=[ph totalSize];
				[array addObject:ph];
			}
		break;
	}

	if(numchannels==1) return [array objectAtIndex:0];
	else return [[[XeeInterleavingHandle alloc] initWithHandles:array elementSize:bitdepth] autorelease];
}

-(int)bitDepth { return bitdepth; }

-(int)mode { return mode; }

@end




@implementation XeePackbitsHandle

-(id)initWithHandle:(CSHandle *)handle rows:(int)numrows bytesPerRow:(int)bpr channel:(int)channel of:(int)numchannels previousSize:(off_t)prevsize
{
	if(self=[super initWithName:[handle name]])
	{
		parent=[handle retain];
		readatmost_ptr=(int (*)(id,SEL,int,void *))[parent methodForSelector:@selector(readAtMost:toBuffer:)];

		rows=numrows;
		bytesperrow=bpr;

		pos=0;
		totalsize=0;
		offsets=malloc(sizeof(off_t)*rows);
		off_t firstrow=[handle offsetInFile]+numchannels*rows*2+prevsize;

		[parent skipBytes:2*rows*channel];
		for(int i=0;i<rows;i++)
		{
			offsets[i]=firstrow+totalsize;
			totalsize+=[parent readUInt16BE];
		}
	}
	return self;
}

-(void)dealloc
{
	free(offsets);
	[parent release];
	[super dealloc];
}


-(off_t)offsetInFile { return pos; }

-(int)readAtMost:(int)num toBuffer:(void *)buffer
{
	uint8 *ptr=buffer;
	int left=num;

	while(left)
	{
		if(pos%bytesperrow==0)
		{
			[parent seekToFileOffset:offsets[pos/bytesperrow]];
			spanleft=0;
		}

		if(!spanleft)
		{
			uint8 b;
			//do {
				if(readatmost_ptr(parent,@selector(readAtMost:toBuffer:),1,&b)!=1) goto end;
			//} while(b==0xff);

			if(b&0x80)
			{
				spanleft=(b^0xff)+2;
				if(readatmost_ptr(parent,@selector(readAtMost:toBuffer:),1,&spanbyte)!=1) goto end;
				literal=NO;
			}
			else
			{
				spanleft=b+1;
				literal=YES;
			}
		}

		if(literal)
		{
			if(readatmost_ptr(parent,@selector(readAtMost:toBuffer:),1,ptr++)!=1) goto end;
		}
		else
		{
			*ptr++=spanbyte;
		}

		spanleft--;
		left--;
		pos++;
	}

	end:
	return num-left;
}

-(off_t)totalSize { return totalsize; }

@end



@implementation XeeDeltaHandle

-(id)initWithHandle:(CSHandle *)handle depth:(int)bitdepth columns:(int)columns
{
	if(self=[super initWithName:[handle name]])
	{
		parent=[handle retain];
//		readatmost_ptr=(int (*)(id,SEL,int,void *))[parent methodForSelector:@selector(readAtMost:toBuffer:)];

		depth=bitdepth;
		cols=columns;
		curr=0;
	}
	return self;
}

-(void)dealloc
{
	[parent release];
	[super dealloc];
}

-(off_t)offsetInFile { return [parent offsetInFile]; }

-(int)readAtMost:(int)num toBuffer:(void *)buffer
{
	off_t start=[parent offsetInFile];
	int actual=[parent readAtMost:num toBuffer:buffer];

	if(depth==16)
	{
		uint8 *ptr=(uint8 *)buffer;
		int first=(start/2)%cols;

		for(int i=0;i<actual/2;i++)
		{
			if((first+i)%cols==0) curr=XeeBEUInt16(ptr);
			else XeeSetBEUInt16(ptr,curr+=XeeBEUInt16(ptr));
			ptr+=2;
		}
	}

	return actual;
}

@end
